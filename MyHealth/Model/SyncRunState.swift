import Foundation

/// Persisted state for an in-progress day-by-day sync. Lives at
/// `Application Support/sync-run-state.json` while a run is active or paused;
/// deleted when the run completes or the user aborts.
///
/// The state is intentionally tiny — no samples are buffered. The day cursor
/// (`completedDayIndex`) and the per-day type cursor (`inProgressTypeIndex`)
/// together pinpoint exactly where to resume. Each entry in `daysToSync`
/// carries its phase so the coordinator can pick the right status string
/// when resuming mid-run.
struct SyncRunState: Codable, Equatable {
    let runID: String
    let startedAt: String
    let daysToSync: [SyncWindow.Entry]
    var completedDayIndex: Int
    var inProgressTypeIndex: Int
}
