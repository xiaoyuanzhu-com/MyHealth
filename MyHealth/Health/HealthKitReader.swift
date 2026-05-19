import Foundation
import HealthKit
import CoreLocation

/// Reads samples from HealthKit using `HKAnchoredObjectQuery` so subsequent
/// runs only see what's new. Anchors are returned to the caller and persisted
/// in the manifest.
struct HealthKitReader {
    let store: HKHealthStore

    init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }

    /// One sync batch: every anchored type is queried once, with the prior
    /// anchor (if any). New samples are encoded and grouped by JSONL file.
    func readBatch(anchors: [String: HKQueryAnchor]) async throws -> SyncReadResult {
        // TODO(Task 7): rewrite this to return per-day bucketed samples.
        print("MyHealth: HealthKitReader.readBatch is stubbed pending Task 7 rewrite")
        return SyncReadResult()
    }

    // MARK: - HKAnchoredObjectQuery wrapper (async)

    private func runAnchoredQuery(
        for type: HKSampleType,
        anchor: HKQueryAnchor?
    ) async throws -> (added: [HKSample], deleted: [HKDeletedObject], newAnchor: HKQueryAnchor?) {
        try await withCheckedThrowingContinuation { cont in
            let query = HKAnchoredObjectQuery(
                type: type,
                predicate: nil,
                anchor: anchor,
                limit: HKObjectQueryNoLimit
            ) { _, samples, deleted, newAnchor, error in
                if let error {
                    cont.resume(throwing: error)
                    return
                }
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
                type: routeType,
                predicate: predicate,
                anchor: nil,
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

    // MARK: - ECG voltage series

    private func loadVoltageSeries(for ecg: HKElectrocardiogram) async throws -> [ECGVoltageSample]? {
        var out: [ECGVoltageSample] = []
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let q = HKElectrocardiogramQuery(ecg) { _, result in
                switch result {
                case .measurement(let m):
                    if let q = m.quantity(for: .appleWatchSimilarToLeadI) {
                        let volts = q.doubleValue(for: .volt())
                        out.append(ECGVoltageSample(t: m.timeSinceSampleStart, v: volts))
                    }
                case .done:
                    cont.resume(returning: ())
                case .error(let e):
                    cont.resume(throwing: e)
                @unknown default:
                    break
                }
            }
            store.execute(q)
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - ActivitySummary

    private func readActivitySummaries(since _: Any?) async throws -> [HealthSample] {
        // TODO(Task 7): activity summaries removed from scope (see plan scope decision #1).
        return []
    }
}

/// Output of one batch read.
struct SyncReadResult {
    var records: [HealthSample] = []
    var workouts: [HealthSample] = []
    var ecgs: [HealthSample] = []
    var clinical: [HealthSample] = []
    var activitySummaries: [HealthSample] = []
    var anchors: [String: HKQueryAnchor] = [:]
    var deleted: [String: Int] = [:]

    var totalCounts: [String: Int] {
        [
            "records": records.count,
            "workouts": workouts.count,
            "ecgs": ecgs.count,
            "clinical": clinical.count,
            "activity_summaries": activitySummaries.count,
        ]
    }
}
