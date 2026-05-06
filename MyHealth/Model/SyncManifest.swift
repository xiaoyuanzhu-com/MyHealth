import Foundation

/// Top-level manifest written to `<remote_root>/manifest.json` after every
/// successful sync. It is the source of truth for incremental sync state:
/// per-type `HKAnchoredObjectQuery` anchors are stored here so a freshly
/// installed copy of MyHealth can resume from the cloud without a full
/// re-export.
struct SyncManifest: Codable, Equatable {
    static let schemaID = "myhealth.healthkit.v1"

    var schema: String = SyncManifest.schemaID
    var device_id: String          // stable per install (UUID in Keychain)
    var device_model: String       // e.g. "iPhone15,2"
    var os_version: String         // e.g. "iOS 17.4"
    var app_version: String        // CFBundleShortVersionString
    var batches: [BatchRef]        // append-only list of past sync batches
    var anchors: [String: String]  // [HKSampleType identifier : base64 anchor]
    var updated_at: String         // ISO 8601

    struct BatchRef: Codable, Equatable {
        let batch_id: String       // "20260506T112233Z"
        let started_at: String
        let finished_at: String
        let counts: [String: Int]  // {"records": 1234, "workouts": 2, ...}
        let files: [FileRef]
    }

    struct FileRef: Codable, Equatable {
        let name: String           // "records.jsonl"
        let size: Int
        let sha256: String
    }
}
