import Foundation

/// File-backed storage for a destination's in-progress `SyncRunState`. Lives
/// at `<Application Support>/sync-run-state-{slug}.json` while a run is
/// active or paused for that destination; deleted when the run completes
/// or the user aborts.
enum SyncRunStore {
    static func url(for destination: Destination) -> URL {
        let dir = try! FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return dir.appendingPathComponent("sync-run-state-\(destination.slug).json")
    }

    static func save(_ state: SyncRunState, for destination: Destination) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(state)
        try data.write(to: url(for: destination), options: .atomic)
    }

    static func load(for destination: Destination) -> SyncRunState? {
        guard let data = try? Data(contentsOf: url(for: destination)) else { return nil }
        return try? JSONDecoder().decode(SyncRunState.self, from: data)
    }

    static func clear(for destination: Destination) {
        try? FileManager.default.removeItem(at: url(for: destination))
    }
}
