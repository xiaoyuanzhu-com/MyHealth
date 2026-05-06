import Foundation
import HealthKit

/// Persists `HKQueryAnchor`s as base64-encoded `NSKeyedArchiver` blobs so the
/// manifest stays plain JSON. Anchors are also kept as a local cache (in
/// `Application Support/anchors.json`) so a fresh install works even before
/// the first manifest round-trip.
struct AnchorStore {
    static let cacheURL: URL = {
        let dir = try! FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return dir.appendingPathComponent("anchors.json")
    }()

    static func encode(_ anchor: HKQueryAnchor) throws -> String {
        let data = try NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
        return data.base64EncodedString()
    }

    static func decode(_ string: String) throws -> HKQueryAnchor? {
        guard let data = Data(base64Encoded: string) else { return nil }
        return try NSKeyedUnarchiver.unarchivedObject(
            ofClass: HKQueryAnchor.self,
            from: data
        )
    }

    static func encodeAll(_ anchors: [String: HKQueryAnchor]) -> [String: String] {
        anchors.compactMapValues { try? encode($0) }
    }

    static func decodeAll(_ encoded: [String: String]) -> [String: HKQueryAnchor] {
        var out: [String: HKQueryAnchor] = [:]
        for (k, v) in encoded {
            if let anchor = try? decode(v) { out[k] = anchor }
        }
        return out
    }

    static func loadCache() -> [String: HKQueryAnchor] {
        guard let data = try? Data(contentsOf: cacheURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return decodeAll(dict)
    }

    static func saveCache(_ anchors: [String: HKQueryAnchor]) {
        let encoded = encodeAll(anchors)
        if let data = try? JSONEncoder().encode(encoded) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }
}
