import Foundation

/// Per-destination per-day fingerprint of the locally-known HealthKit
/// content that was uploaded to that destination. Used by the sync
/// coordinator's backward walk to detect "this day still matches what we
/// last synced to this destination" → wall found, stop walking.
///
/// Stored at `<Application Support>/day-hashes-{slug}.json` as a flat map
/// `[date-string: hex-hash]`. Each entry is a SHA256 of the deterministic
/// per-type sample dump for that day; see `HealthKitReader.dayHash(day:)`.
///
/// On first sync to a destination (no entries yet), the coordinator uses a
/// cheaper "any sample exists on this day?" probe instead of computing
/// hashes — any data without a stored fingerprint counts as "updates exist".
enum DayHashStore {
    static func url(for destination: Destination) -> URL {
        let dir = try! FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return dir.appendingPathComponent("day-hashes-\(destination.slug).json")
    }

    static func load(for destination: Destination) -> [String: String] {
        guard let data = try? Data(contentsOf: url(for: destination)),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return dict
    }

    static func save(_ hashes: [String: String], for destination: Destination) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(hashes)
        try data.write(to: url(for: destination), options: .atomic)
    }
}
