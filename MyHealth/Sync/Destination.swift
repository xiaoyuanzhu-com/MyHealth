import Foundation

/// The three remote sync targets MyHealth can push day-files to.
///
/// Files-app export is intentionally not a `Destination`: it's a one-shot,
/// full-export operation with no cursor, no hashes, and a different UI
/// pathway. See `FilesExporter`.
///
/// The `slug` is used as a stable on-disk key for per-destination state
/// files (cursor, day-hashes, run-state) and for the per-destination
/// `LastSyncStore` UserDefaults entries. Slugs must not change once
/// shipped — the migration step depends on the exact spellings.
enum Destination: String, CaseIterable, Codable, Identifiable, Sendable {
    case myLifeDB
    case googleDrive
    case webdav

    var id: String { rawValue }

    /// On-disk filename component. e.g. `sync-cursor-mylifedb.json`.
    var slug: String {
        switch self {
        case .myLifeDB:    return "mylifedb"
        case .googleDrive: return "drive"
        case .webdav:      return "webdav"
        }
    }
}
