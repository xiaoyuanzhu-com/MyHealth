import Foundation
import CryptoKit

/// Writes JSONL files for one sync batch into the app's tmp directory. Each
/// file's SHA-256 is computed during write so the manifest can record it
/// without re-reading.
struct BatchWriter {
    let batchID: String
    let dir: URL

    /// JSON encoder configured to produce deterministic output:
    ///  - keys sorted (stable diffs / dedupe across runs)
    ///  - no extra whitespace
    ///  - no escaped slashes
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    init() throws {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
        self.batchID = stamp
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("myhealth-batch-\(stamp)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        self.dir = tmp
    }

    /// Writes `samples` to `<dir>/<filename>` as JSONL. Returns metadata for
    /// the manifest, or nil if `samples` is empty (no file is created).
    @discardableResult
    func writeJSONL(_ samples: [HealthSample], filename: String) throws -> SyncManifest.FileRef? {
        guard !samples.isEmpty else { return nil }
        let url = dir.appendingPathComponent(filename)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw NSError(domain: "BatchWriter", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create \(url.path)"])
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        var byteCount = 0

        for sample in samples {
            var line = try Self.encoder.encode(sample)
            line.append(0x0A) // '\n'
            try handle.write(contentsOf: line)
            hasher.update(data: line)
            byteCount += line.count
        }

        let digest = hasher.finalize()
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return SyncManifest.FileRef(name: filename, size: byteCount, sha256: hex)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: dir)
    }
}
