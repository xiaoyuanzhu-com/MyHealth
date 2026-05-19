import Foundation
import HealthKit
import CoreLocation
import CryptoKit

/// Reads HealthKit samples one day-at-a-time, one type-at-a-time. Memory is
/// bounded to a single `(day, type)` slice. No anchored queries — the caller
/// (SyncCoordinator) drives iteration via the day cursor.
struct HealthKitReader {
    let store: HKHealthStore

    init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }

    /// Quantity samples for one type, restricted to `day`'s `[00:00, 24:00)`
    /// in the day's own timezone.
    func readQuantity(type: HKQuantityType, day: DayBucketer.DayKey) async throws -> [QuantitySample] {
        let predicate = dayPredicate(day: day)
        let samples: [HKSample] = try await runSampleQuery(type: type, predicate: predicate)
        return samples.compactMap { sample in
            guard let q = sample as? HKQuantitySample else { return nil }
            return SampleEncoder.encode(q)
        }
    }

    /// Category samples for one type for `day`.
    func readCategory(type: HKCategoryType, day: DayBucketer.DayKey) async throws -> [CategorySample] {
        let predicate = dayPredicate(day: day)
        let samples: [HKSample] = try await runSampleQuery(type: type, predicate: predicate)
        return samples.compactMap { sample in
            guard let c = sample as? HKCategorySample else { return nil }
            return SampleEncoder.encode(c)
        }
    }

    /// Workouts whose `startDate` falls in `day`. Caller iterates and calls
    /// `loadRoute(for:)` per workout, so route memory is per-workout-bounded.
    func readWorkouts(day: DayBucketer.DayKey) async throws -> [HKWorkout] {
        let predicate = dayPredicate(day: day)
        let samples: [HKSample] = try await runSampleQuery(
            type: HKObjectType.workoutType(),
            predicate: predicate
        )
        return samples.compactMap { $0 as? HKWorkout }
    }

    /// True if any anchored sample type has at least one sample on `day`.
    /// Short-circuits on the first non-empty type. Memory-bounded: each
    /// underlying query uses `limit: 1`. Used as the cheap probe during
    /// the backward walk on first sync (no stored hashes yet).
    func dayHasAnySample(day: DayBucketer.DayKey) async -> Bool {
        let predicate = dayPredicate(day: day)
        for type in HealthDataTypes.allAnchoredSampleTypes {
            if (try? await firstSampleExists(type: type, predicate: predicate)) == true {
                return true
            }
        }
        return false
    }

    /// SHA256 hex of the canonicalized HealthKit content for `day`, across
    /// every anchored sample type. Same content → same hash. Streams one
    /// type at a time into the hasher, so memory stays bounded to a single
    /// `(day, type)` slice even though all types contribute. Returns the
    /// digest of "no samples" when the day is empty across all types — that
    /// fixed value is the wall signal for the backward walk on first sync.
    func dayHash(day: DayBucketer.DayKey) async throws -> String {
        var hasher = SHA256()
        for type in HealthDataTypes.allAnchoredSampleTypes {
            let segment = try await canonicalSegment(type: type, day: day)
            hasher.update(data: Data(segment.utf8))
            hasher.update(data: Data("\n".utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Deterministic string representation of `type`'s samples on `day`.
    /// Empty types produce `"<type-id>:"` so two empty days hash identically.
    private func canonicalSegment(type: HKSampleType, day: DayBucketer.DayKey) async throws -> String {
        let predicate = dayPredicate(day: day)
        let samples = try await runSampleQuery(type: type, predicate: predicate)
        let encoded: [String]
        if type is HKQuantityType {
            encoded = samples.compactMap { ($0 as? HKQuantitySample).flatMap(SampleEncoder.encode) }
                .map { sortedJSON($0) }
        } else if type is HKCategoryType {
            encoded = samples.compactMap { ($0 as? HKCategorySample).map(SampleEncoder.encode) }
                .map { sortedJSON($0) }
        } else if type is HKWorkoutType {
            encoded = samples.compactMap { $0 as? HKWorkout }.map { workoutFingerprint($0) }
        } else {
            encoded = []
        }
        return "\(type.identifier):\(encoded.sorted().joined(separator: ","))"
    }

    private func sortedJSON<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(value)) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Workouts only need an identity fingerprint here — the actual upload
    /// is keyed by UUID with no merge, so what we care about is "did the
    /// set of workouts on this day change?". UUID + start + end captures it.
    private func workoutFingerprint(_ w: HKWorkout) -> String {
        "\(w.uuid.uuidString)|\(w.startDate.timeIntervalSince1970)|\(w.endDate.timeIntervalSince1970)"
    }

    private func firstSampleExists(type: HKSampleType, predicate: NSPredicate) async throws -> Bool {
        try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(
                sampleType: type, predicate: predicate, limit: 1,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    if let hk = error as? HKError,
                       hk.code == .errorAuthorizationNotDetermined || hk.code == .errorAuthorizationDenied {
                        cont.resume(returning: false)
                        return
                    }
                    cont.resume(throwing: error)
                    return
                }
                cont.resume(returning: !(samples?.isEmpty ?? true))
            }
            store.execute(q)
        }
    }

    /// Earliest day across all anchored sample types that has any sample.
    /// Used on first sync to bound the back-fill range. Returns nil if HK
    /// returns no samples for any type (empty store or all-denied auth).
    ///
    /// One ascending-sort `HKSampleQuery(limit: 1)` per type — typically
    /// 142 lightweight queries; HealthKit answers each in O(log n) on its
    /// internal index. Bounded to ~140 small allocations; never buffers
    /// content.
    func oldestDataDay(timezone: TimeZone = .current) async -> DayBucketer.DayKey? {
        var oldest: Date?
        for type in HealthDataTypes.allAnchoredSampleTypes {
            if let earliest = try? await firstSampleDate(type: type) {
                if let cur = oldest {
                    if earliest < cur { oldest = earliest }
                } else {
                    oldest = earliest
                }
            }
        }
        guard let oldest else { return nil }
        return DayBucketer.dayKey(start: oldest, timezone: timezone)
    }

    private func firstSampleDate(type: HKSampleType) async throws -> Date? {
        try await withCheckedThrowingContinuation { cont in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            let q = HKSampleQuery(
                sampleType: type, predicate: nil, limit: 1,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    if let hk = error as? HKError,
                       hk.code == .errorAuthorizationNotDetermined || hk.code == .errorAuthorizationDenied {
                        cont.resume(returning: nil)
                        return
                    }
                    cont.resume(throwing: error)
                    return
                }
                cont.resume(returning: samples?.first?.startDate)
            }
            store.execute(q)
        }
    }

    /// Locations for a single workout's route. Returns nil if no route was recorded.
    func loadRoute(for workout: HKWorkout) async throws -> [CLLocation]? {
        let routeType = HealthDataTypes.workoutRouteType
        let predicate = HKQuery.predicateForObjects(from: workout)
        let routes: [HKWorkoutRoute] = try await withCheckedThrowingContinuation { cont in
            let q = HKAnchoredObjectQuery(
                type: routeType, predicate: predicate, anchor: nil,
                limit: HKObjectQueryNoLimit
            ) { _, samples, _, _, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: (samples as? [HKWorkoutRoute]) ?? [])
            }
            store.execute(q)
        }
        guard !routes.isEmpty else { return nil }

        var locations: [CLLocation] = []
        for route in routes {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let routeQuery = HKWorkoutRouteQuery(route: route) { _, batch, done, error in
                    if let error { cont.resume(throwing: error); return }
                    if let batch { locations.append(contentsOf: batch) }
                    if done { cont.resume(returning: ()) }
                }
                store.execute(routeQuery)
            }
        }
        return locations.isEmpty ? nil : locations
    }

    // MARK: - Predicate

    /// `[startOfDay, startOfNextDay)` in the day's own timezone.
    private func dayPredicate(day: DayBucketer.DayKey) -> NSPredicate {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: day.timezone) ?? .current
        let formatter = DateFormatter()
        formatter.calendar = cal
        formatter.timeZone = cal.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let start = formatter.date(from: day.date) ?? Date()
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        return HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictStartDate])
    }

    // MARK: - HKSampleQuery wrapper

    private func runSampleQuery(type: HKSampleType, predicate: NSPredicate) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { cont in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    if let hk = error as? HKError,
                       hk.code == .errorAuthorizationNotDetermined || hk.code == .errorAuthorizationDenied {
                        cont.resume(returning: [])
                        return
                    }
                    cont.resume(throwing: error)
                    return
                }
                cont.resume(returning: samples ?? [])
            }
            store.execute(query)
        }
    }
}
