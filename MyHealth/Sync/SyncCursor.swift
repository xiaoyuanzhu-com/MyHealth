import Foundation

struct SyncCursor: Codable, Equatable {
    var earliestSyncedDay: DayBucketer.DayKey?
    var latestSyncedDay: DayBucketer.DayKey?
}
