import Foundation

/// Per-day fingerprint of locally-known HealthKit content. Used by the
/// sync coordinator's backward walk to detect "this day still matches
/// what we last synced" → wall found, stop walking.
///
/// Stored at `<Application Support>/day-hashes.json` as a flat map
/// `[date-string: hex-hash]`. Each entry is a SHA256 of the deterministic
/// per-type sample dump for that day; see `HealthKitReader.dayHash(day:)`.
///
/// On first sync (no entries yet), the coordinator uses a cheaper
/// "any sample exists on this day?" probe instead of computing hashes —
/// any data without a stored fingerprint counts as "updates exist".
enum DayHashStore {
    static let defaultURL: URL = {
        let dir = try! FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return dir.appendingPathComponent("day-hashes.json")
    }()

    static func load(at url: URL = defaultURL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return dict
    }

    static func save(_ hashes: [String: String], at url: URL = defaultURL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(hashes)
        try data.write(to: url, options: .atomic)
    }
}
