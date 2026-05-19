import Foundation

/// Persisted state for an in-progress day-by-day sync. Lives at
/// `Application Support/sync-run-state.json` while a run is active or paused;
/// deleted when the run completes or the user aborts.
///
/// The state is intentionally tiny — no samples are buffered. The day cursor
/// (`completedDayIndex`) and the per-day type cursor (`inProgressTypeIndex`)
/// together pinpoint exactly where to resume. Both indices count "fully
/// uploaded" units, so a fresh run starts at (0, 0) and a run that has
/// uploaded the first day fully and is mid-way through the second day's
/// 45th type checkpoint sits at (1, 45).
struct SyncRunState: Codable, Equatable {
    let runID: String
    let startedAt: String
    let daysToSync: [DayBucketer.DayKey]
    var completedDayIndex: Int
    var inProgressTypeIndex: Int
}
