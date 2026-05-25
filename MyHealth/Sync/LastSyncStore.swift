import Foundation

/// Per-target "most recent successful completion" timestamps. Backed by
/// `UserDefaults` (small payload, atomic writes for free). Read by detail
/// pages and sync target rows to show "Last synced 2h ago".
///
/// Files export is treated as a fourth target here even though it isn't a
/// `Destination` — exporters and remote syncers both produce a "last
/// successful run" instant the UI cares about.
enum LastSyncStore {
    private static let prefix = "lastSyncedAt."
    private static let filesKey = "lastExportedAt"

    static func load(for destination: Destination) -> Date? {
        UserDefaults.standard.object(forKey: prefix + destination.slug) as? Date
    }

    static func stamp(_ date: Date = Date(), for destination: Destination) {
        UserDefaults.standard.set(date, forKey: prefix + destination.slug)
    }

    static func loadFilesExport() -> Date? {
        UserDefaults.standard.object(forKey: filesKey) as? Date
    }

    static func stampFilesExport(_ date: Date = Date()) {
        UserDefaults.standard.set(date, forKey: filesKey)
    }
}
