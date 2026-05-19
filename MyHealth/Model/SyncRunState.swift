import Foundation

/// Persisted state for an in-progress day-by-day sync. Lives at
/// `Application Support/sync-run-state.json` while a run is active or paused;
/// deleted when the run completes or the user aborts.
///
/// `daysToSync` is the forward-sync plan computed at the start of a run
/// (oldest → newest, anchor day inclusive). `completedDayIndex` and
/// `inProgressTypeIndex` together pinpoint where to resume mid-run.
struct SyncRunState: Codable, Equatable {
    let runID: String
    let startedAt: String
    let daysToSync: [DayBucketer.DayKey]
    var completedDayIndex: Int
    var inProgressTypeIndex: Int
}
