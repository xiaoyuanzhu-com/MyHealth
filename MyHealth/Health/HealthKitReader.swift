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
    func readBatch(
        anchors: [String: HKQueryAnchor]
    ) async throws -> SyncReadResult {
        var result = SyncReadResult()

        for sampleType in HealthDataTypes.allAnchoredSampleTypes {
            let prev = anchors[sampleType.identifier]
            let (samples, deleted, newAnchor) = try await runAnchoredQuery(
                for: sampleType,
                anchor: prev
            )

            result.deleted[sampleType.identifier] = deleted.count
            if let newAnchor { result.anchors[sampleType.identifier] = newAnchor }

            for sample in samples {
                if let workout = sample as? HKWorkout {
                    let events = workout.workoutEvents
                    let route = try await loadRoute(for: workout)
                    let row = SampleEncoder.encode(workout, events: events, route: route)
                    result.workouts.append(row)
                } else if let ecg = sample as? HKElectrocardiogram {
                    let voltage = try await loadVoltageSeries(for: ecg)
                    result.ecgs.append(SampleEncoder.encode(ecg, voltage: voltage))
                } else if let q = sample as? HKQuantitySample {
                    if let row = SampleEncoder.encode(q) {
                        result.records.append(row)
                    }
                } else if let c = sample as? HKCategorySample {
                    result.records.append(SampleEncoder.encode(c))
                } else if let cr = sample as? HKClinicalRecord {
                    result.clinical.append(SampleEncoder.encode(cr))
                }
            }
        }

        // ActivitySummary uses a different query type (no anchored variant).
        result.activitySummaries = try await readActivitySummaries(
            since: anchors["HKActivitySummaryTypeIdentifier"].flatMap { _ in nil } // no anchor concept
        )

        return result
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
        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        // Fetch the last 365 days of summaries every sync. Cheap, idempotent,
        // safer than relying on per-day anchors that HealthKit doesn't expose.
        let start = cal.date(byAdding: .day, value: -365, to: now) ?? now
        var startC = cal.dateComponents([.year, .month, .day], from: start)
        var endC = cal.dateComponents([.year, .month, .day], from: now)
        startC.calendar = cal
        endC.calendar = cal
        let predicate = HKQuery.predicate(forActivitySummariesBetweenStart: startC, end: endC)
        let summaries: [HKActivitySummary] = try await withCheckedThrowingContinuation { cont in
            let q = HKActivitySummaryQuery(predicate: predicate) { _, summaries, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: summaries ?? [])
            }
            store.execute(q)
        }
        return summaries.map(SampleEncoder.encode)
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
