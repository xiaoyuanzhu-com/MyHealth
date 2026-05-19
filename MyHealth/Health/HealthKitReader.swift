import Foundation
import HealthKit
import CoreLocation
import UIKit

/// Reads new HealthKit samples (since the previous anchors) and buckets them
/// by local day. Output is suitable for direct insertion into a
/// `SyncRunState`.
struct HealthKitReader {
    let store: HKHealthStore

    init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }

    /// One read pass over every anchored type. Returns:
    ///   - per-day buckets sorted oldest-first
    ///   - new anchor per type (only for types that returned data or moved forward)
    func readBucketed(
        anchors: [String: HKQueryAnchor],
        deviceInfo: WorkoutFile.DeviceInfo
    ) async throws -> ReadResult {
        // Mutable accumulators keyed by DayKey. Per-type sample arrays inside.
        var buckets: [DayBucketer.DayKey: BucketAccumulator] = [:]
        var newAnchors: [String: HKQueryAnchor] = [:]

        for sampleType in HealthDataTypes.allAnchoredSampleTypes {
            let prev = anchors[sampleType.identifier]
            let queryResult: (added: [HKSample], deleted: [HKDeletedObject], newAnchor: HKQueryAnchor?)
            do {
                queryResult = try await runAnchoredQuery(for: sampleType, anchor: prev)
            } catch let e as HKError where e.code == .errorAuthorizationNotDetermined || e.code == .errorAuthorizationDenied {
                print("MyHealth: skip \(sampleType.identifier) (no auth): \(e.localizedDescription)")
                continue
            }
            let (samples, _, newAnchor) = queryResult
            if let newAnchor { newAnchors[sampleType.identifier] = newAnchor }

            for sample in samples {
                if let workout = sample as? HKWorkout {
                    // Workouts: build a WorkoutFile per workout.
                    let events = workout.workoutEvents
                    let route = (try? await loadRoute(for: workout)) ?? nil
                    let wf = SampleEncoder.encode(workout, events: events, route: route, deviceInfo: deviceInfo)
                    let tz = SampleEncoder.timezone(from: workout.metadata)
                    let key = DayBucketer.dayKey(start: workout.startDate, timezone: tz)
                    buckets[key, default: BucketAccumulator()].workouts.append(wf)

                } else if let q = sample as? HKQuantitySample {
                    guard let row = SampleEncoder.encode(q) else { continue }
                    let tz = SampleEncoder.timezone(from: q.metadata)
                    let key = DayBucketer.dayKey(start: q.startDate, timezone: tz)
                    buckets[key, default: BucketAccumulator()].quantity[q.quantityType.identifier, default: []].append(row)

                } else if let c = sample as? HKCategorySample {
                    let row = SampleEncoder.encode(c)
                    let tz = SampleEncoder.timezone(from: c.metadata)
                    let key = DayBucketer.dayKey(start: c.startDate, timezone: tz)
                    buckets[key, default: BucketAccumulator()].category[c.categoryType.identifier, default: []].append(row)
                }
            }
        }

        let sortedKeys = buckets.keys.sorted { $0.date < $1.date }
        let dayBuckets: [SyncRunState.DayBucket] = sortedKeys.map { key in
            let acc = buckets[key]!
            // Wrap each sample so its uuid travels through SyncRunState's
            // wire format without polluting the QuantitySample/CategorySample
            // wire format used by uploaded day-files.
            let quantityWrapped: [String: [PersistedQuantitySample]] = acc.quantity.mapValues {
                $0.map(PersistedQuantitySample.init)
            }
            let categoryWrapped: [String: [PersistedCategorySample]] = acc.category.mapValues {
                $0.map(PersistedCategorySample.init)
            }
            return SyncRunState.DayBucket(
                key: key,
                quantitySamples: quantityWrapped,
                categorySamples: categoryWrapped,
                workouts: acc.workouts
            )
        }
        return ReadResult(buckets: dayBuckets, newAnchors: newAnchors)
    }

    struct ReadResult {
        let buckets: [SyncRunState.DayBucket]
        let newAnchors: [String: HKQueryAnchor]
    }

    private struct BucketAccumulator {
        var quantity: [String: [QuantitySample]] = [:]
        var category: [String: [CategorySample]] = [:]
        var workouts: [WorkoutFile] = []
    }

    // MARK: - HKAnchoredObjectQuery wrapper

    private func runAnchoredQuery(
        for type: HKSampleType,
        anchor: HKQueryAnchor?
    ) async throws -> (added: [HKSample], deleted: [HKDeletedObject], newAnchor: HKQueryAnchor?) {
        try await withCheckedThrowingContinuation { cont in
            let query = HKAnchoredObjectQuery(
                type: type, predicate: nil, anchor: anchor,
                limit: HKObjectQueryNoLimit
            ) { _, samples, deleted, newAnchor, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: (samples ?? [], deleted ?? [], newAnchor))
            }
            store.execute(query)
        }
    }

    // MARK: - Workout route

    private func loadRoute(for workout: HKWorkout) async throws -> [CLLocation]? {
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
}
