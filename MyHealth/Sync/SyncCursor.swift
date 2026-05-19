import Foundation

/// Persistent watermark for day-by-day sync. Stored at
/// `<Application Support>/sync-cursor.json`. Advances to `today` only when
/// a full sync run (forward + double-check) completes successfully.
///
/// Semantics: `lastSyncedDay` is the most recent day fully synced. The next
/// sync run re-syncs *from* that day forward (in case data landed in it
/// after the previous run finished) and double-checks the week before it.
struct SyncCursor: Codable, Equatable {
    var lastSyncedDay: DayBucketer.DayKey?

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
        else { return SyncCursor(lastSyncedDay: nil) }
        return cursor
    }

    static func save(_ cursor: SyncCursor, at url: URL = defaultURL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        let data = try encoder.encode(cursor)
        try data.write(to: url, options: .atomic)
    }
}
