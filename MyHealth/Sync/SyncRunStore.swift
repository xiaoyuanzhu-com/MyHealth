import Foundation

/// File-backed storage for `SyncRunState`. Default location is
/// `<Application Support>/sync-run-state.json`.
enum SyncRunStore {

    static let defaultURL: URL = {
        let dir = try! FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return dir.appendingPathComponent("sync-run-state.json")
    }()

    static func save(_ state: SyncRunState, at url: URL = defaultURL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(state)
        try data.write(to: url, options: .atomic)
    }

    static func load(at url: URL = defaultURL) -> SyncRunState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SyncRunState.self, from: data)
    }

    static func clear(at url: URL = defaultURL) {
        try? FileManager.default.removeItem(at: url)
    }
}
