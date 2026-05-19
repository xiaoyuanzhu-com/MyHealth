import Foundation
import HealthKit
import CoreLocation

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
