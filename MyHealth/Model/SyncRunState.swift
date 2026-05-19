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
        let quantitySamples: [String: [PersistedQuantitySample]]
        let categorySamples: [String: [PersistedCategorySample]]
        let workouts: [WorkoutFile]
    }

    var remainingDays: ArraySlice<DayBucket> {
        guard completedDayCount < buckets.count else { return [] }
        return buckets[completedDayCount...]
    }
}

/// On-disk wrapper that carries a QuantitySample alongside its HealthKit
/// UUID. The UUID is needed at runtime for snapshot-merge dedup but must
/// NOT appear in the published day-file wire format — so we keep it
/// separate here and let QuantitySample stay uuid-free in its own JSON.
struct PersistedQuantitySample: Codable, Equatable {
    /// The sample as it appears in the wire format (uuid always nil here).
    let sample: QuantitySample
    /// The HealthKit UUID, stored at the wrapper level so it never leaks into
    /// the published day-file wire format.
    let uuid: String?

    init(_ s: QuantitySample) {
        // Strip uuid from the inner sample so it stays out of the wire format
        // and so equality holds after a JSON round-trip (decoder always produces
        // sample.uuid == nil).
        self.sample = QuantitySample(
            start: s.start, end: s.end, value: s.value, unit: s.unit,
            type: s.type, source: s.source, device: s.device,
            metadata: s.metadata, uuid: nil
        )
        self.uuid = s.uuid
    }

    init(sample: QuantitySample, uuid: String?) {
        self.sample = sample
        self.uuid = uuid
    }

    /// Reconstitutes a QuantitySample with the saved uuid wired back in.
    func toSample() -> QuantitySample {
        QuantitySample(
            start: sample.start, end: sample.end, value: sample.value,
            unit: sample.unit, type: sample.type, source: sample.source,
            device: sample.device, metadata: sample.metadata, uuid: uuid
        )
    }
}

struct PersistedCategorySample: Codable, Equatable {
    /// The sample as it appears in the wire format (uuid always nil here).
    let sample: CategorySample
    /// The HealthKit UUID, stored at the wrapper level so it never leaks into
    /// the published day-file wire format.
    let uuid: String?

    init(_ s: CategorySample) {
        // Strip uuid from the inner sample so it stays out of the wire format
        // and so equality holds after a JSON round-trip.
        self.sample = CategorySample(
            start: s.start, end: s.end, value: s.value,
            type: s.type, source: s.source, device: s.device,
            metadata: s.metadata, uuid: nil
        )
        self.uuid = s.uuid
    }

    init(sample: CategorySample, uuid: String?) {
        self.sample = sample
        self.uuid = uuid
    }

    func toSample() -> CategorySample {
        CategorySample(
            start: sample.start, end: sample.end, value: sample.value,
            type: sample.type, source: sample.source,
            device: sample.device, metadata: sample.metadata, uuid: uuid
        )
    }
}
