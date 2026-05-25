import Foundation

/// Per-destination watermark for day-by-day sync. Stored at
/// `<Application Support>/sync-cursor-{slug}.json`. Advances to the newest
/// day in the run plan only when a full sync run completes successfully
/// for that destination.
///
/// Semantics: `lastSyncedDay` is the most recent day fully synced to this
/// destination. The next run re-syncs from that day forward (in case data
/// landed in it after the previous run finished) and walks back to find
/// the first mismatching day.
struct SyncCursor: Codable, Equatable {
    var lastSyncedDay: DayBucketer.DayKey?

    static func url(for destination: Destination) -> URL {
        let dir = try! FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return dir.appendingPathComponent("sync-cursor-\(destination.slug).json")
    }

    static func load(for destination: Destination) -> SyncCursor {
        guard let data = try? Data(contentsOf: url(for: destination)),
              let cursor = try? JSONDecoder().decode(SyncCursor.self, from: data)
        else { return SyncCursor(lastSyncedDay: nil) }
        return cursor
    }

    static func save(_ cursor: SyncCursor, for destination: Destination) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        let data = try encoder.encode(cursor)
        try data.write(to: url(for: destination), options: .atomic)
    }
}
