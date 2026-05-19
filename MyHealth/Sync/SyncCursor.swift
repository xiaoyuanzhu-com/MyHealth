import Foundation

/// Persistent watermark for day-by-day sync. Stored at
/// `<Application Support>/sync-cursor.json`. Advances only when a full
/// sync run completes.
struct SyncCursor: Codable, Equatable {
    var earliestSyncedDay: DayBucketer.DayKey?
    var latestSyncedDay: DayBucketer.DayKey?

    static let defaultURL: URL = {
        let dir = try! FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return dir.appendingPathComponent("sync-cursor.json")
    }()

    static func load(at url: URL = defaultURL) -> SyncCursor {
        guard let data = try? Data(contentsOf: url),
              let cursor = try? JSONDecoder().decode(SyncCursor.self, from: data)
        else { return SyncCursor(earliestSyncedDay: nil, latestSyncedDay: nil) }
        return cursor
    }

    static func save(_ cursor: SyncCursor, at url: URL = defaultURL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        let data = try encoder.encode(cursor)
        try data.write(to: url, options: .atomic)
    }

    /// Updates the cursor to reflect that every day in `coveredDays` has been
    /// fully synced in the just-completed run. `coveredDays` may be in any
    /// order; `earliestSyncedDay` advances to the oldest and `latestSyncedDay`
    /// to the newest, monotonically (never moves backward).
    mutating func advance(coveredDays: [DayBucketer.DayKey]) {
        guard let newest = coveredDays.max(by: { $0.date < $1.date }),
              let oldest = coveredDays.min(by: { $0.date < $1.date }) else { return }
        if let existing = latestSyncedDay {
            if newest.date > existing.date { latestSyncedDay = newest }
        } else {
            latestSyncedDay = newest
        }
        if let existing = earliestSyncedDay {
            if oldest.date < existing.date { earliestSyncedDay = oldest }
        } else {
            earliestSyncedDay = oldest
        }
    }
}
