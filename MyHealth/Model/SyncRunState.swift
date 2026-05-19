import Foundation

/// Persisted state for an in-progress sync run. Lives at
/// `Application Support/sync-run-state.json` while a run is active or paused;
/// deleted when the run completes or the user aborts.
///
/// Each `DayBucket` holds the per-(type, day) sample lists already read from
/// HealthKit but not yet uploaded. `completedDayCount` is the resume cursor:
/// indexes < completedDayCount have been uploaded.
struct SyncRunState: Codable, Equatable {
    let runID: String                            // "20260518T120000Z"
    let startedAt: String                        // ISO 8601 UTC
    let anchorsAtStart: [String: String]         // base64-encoded HKQueryAnchor per type
    let newAnchors: [String: String]             // anchors HealthKit returned at read time
    let buckets: [DayBucket]                     // sorted oldest-first
    var completedDayCount: Int                   // number of buckets fully uploaded

    struct DayBucket: Codable, Equatable {
        let key: DayBucketer.DayKey
        // Per-type sample arrays. Map key = full HK identifier ("HKQuantity…").
        let quantitySamples: [String: [QuantitySample]]
        let categorySamples: [String: [CategorySample]]
        let workouts: [WorkoutFile]
    }

    var remainingDays: ArraySlice<DayBucket> {
        guard completedDayCount < buckets.count else { return [] }
        return buckets[completedDayCount...]
    }
}
