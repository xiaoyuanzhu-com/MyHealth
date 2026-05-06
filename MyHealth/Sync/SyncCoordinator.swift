import Foundation
import HealthKit
import UIKit

/// Orchestrates one sync run end-to-end:
///   1. Loads previous anchors (manifest from MyLifeDB → local cache → empty)
///   2. Reads new HealthKit samples since those anchors
///   3. Groups samples into JSONL files
///   4. Uploads to every authorised destination (MyLifeDB, Google Drive)
///   5. Persists updated anchors in a refreshed manifest (last upload, atomic-ish)
@MainActor
final class SyncCoordinator: ObservableObject {
    @Published private(set) var status: SyncStatus = .idle
    @Published private(set) var lastResult: SyncRunResult?

    enum SyncStatus: Equatable {
        case idle
        case running(stage: String)
        case error(String)
    }

    struct SyncRunResult: Equatable {
        let batchID: String
        let counts: [String: Int]
        let myLifeDBUploaded: Bool
        let driveUploaded: Bool
        let finishedAt: Date
    }

    enum Destination { case myLifeDB, googleDrive }

    private let reader: HealthKitReader
    private let manifestPath = "manifest.json"

    init(reader: HealthKitReader = HealthKitReader()) {
        self.reader = reader
    }

    /// Runs one full sync. `enabledDestinations` controls which targets to
    /// upload to (auth status is checked per destination).
    func runOnce(enabledDestinations: Set<Destination>) async {
        let started = Date()
        do {
            status = .running(stage: "Loading manifest")
            let mldSession = try TokenStore.load()
            let mldClient = mldSession.map { MyLifeDBClient(session: $0) }

            // 1. Load anchors: prefer MyLifeDB manifest, fall back to local cache.
            var anchors: [String: HKQueryAnchor] = [:]
            var manifest: SyncManifest? = nil
            if enabledDestinations.contains(.myLifeDB), let mld = mldClient {
                if let data = try? await mld.getFile(relativePath: manifestPath),
                   let parsed = try? JSONDecoder().decode(SyncManifest.self, from: data) {
                    manifest = parsed
                    anchors = AnchorStore.decodeAll(parsed.anchors)
                }
            }
            if anchors.isEmpty {
                anchors = AnchorStore.loadCache()
            }

            // 2. Read new samples.
            status = .running(stage: "Reading HealthKit")
            let result = try await reader.readBatch(anchors: anchors)

            // 3. Write JSONL batch files locally.
            status = .running(stage: "Writing batch")
            let writer = try BatchWriter()
            defer { writer.cleanup() }
            var files: [SyncManifest.FileRef] = []
            if let r = try writer.writeJSONL(result.records, filename: "records.jsonl") { files.append(r) }
            if let r = try writer.writeJSONL(result.workouts, filename: "workouts.jsonl") { files.append(r) }
            if let r = try writer.writeJSONL(result.activitySummaries, filename: "activity_summaries.jsonl") { files.append(r) }
            if let r = try writer.writeJSONL(result.ecgs, filename: "ecg.jsonl") { files.append(r) }
            if let r = try writer.writeJSONL(result.clinical, filename: "clinical.jsonl") { files.append(r) }

            // Even when there are zero new samples we still refresh the
            // manifest so the user can see "last sync = X" remotely.
            let totalSamples = files.reduce(0) { $0 + $1.size }
            print("MyHealth: batch \(writer.batchID) — \(files.count) files, \(totalSamples) bytes")

            // 4. Build/update manifest with new anchors + batch entry.
            let now = ISO8601DateFormatter().string(from: Date())
            let batchRef = SyncManifest.BatchRef(
                batch_id: writer.batchID,
                started_at: ISO8601DateFormatter().string(from: started),
                finished_at: now,
                counts: result.totalCounts,
                files: files
            )
            var batches = manifest?.batches ?? []
            if !files.isEmpty { batches.append(batchRef) }
            let mergedAnchors = anchors.merging(result.anchors) { _, new in new }
            let newManifest = SyncManifest(
                schema: SyncManifest.schemaID,
                device_id: manifest?.device_id ?? deviceID(),
                device_model: deviceModel(),
                os_version: osVersion(),
                app_version: appVersion(),
                batches: batches,
                anchors: AnchorStore.encodeAll(mergedAnchors),
                updated_at: now
            )
            AnchorStore.saveCache(mergedAnchors)

            // 5. Upload to each enabled destination.
            var didUploadMLD = false
            var didUploadDrive = false

            if enabledDestinations.contains(.myLifeDB), let mld = mldClient, !files.isEmpty {
                status = .running(stage: "Uploading to MyLifeDB")
                for file in files {
                    let local = writer.dir.appendingPathComponent(file.name)
                    let remote = "syncs/\(writer.batchID)/\(file.name)"
                    try await mld.putFile(relativePath: remote, localFile: local)
                }
            }
            if enabledDestinations.contains(.myLifeDB), let mld = mldClient {
                let manifestData = try JSONEncoder.deterministic.encode(newManifest)
                try await mld.putBytes(relativePath: manifestPath, body: manifestData, contentType: "application/json")
                didUploadMLD = true
            }

            if enabledDestinations.contains(.googleDrive), DriveAuth.currentUser != nil {
                status = .running(stage: "Uploading to Google Drive")
                let drive = GoogleDriveClient()
                if !files.isEmpty {
                    for file in files {
                        let local = writer.dir.appendingPathComponent(file.name)
                        let remote = "syncs/\(writer.batchID)/\(file.name)"
                        try await drive.uploadFile(relativePath: remote, localFile: local)
                    }
                }
                let manifestData = try JSONEncoder.deterministic.encode(newManifest)
                try await drive.uploadBytes(relativePath: manifestPath, body: manifestData)
                didUploadDrive = true
            }

            let runResult = SyncRunResult(
                batchID: writer.batchID,
                counts: result.totalCounts,
                myLifeDBUploaded: didUploadMLD,
                driveUploaded: didUploadDrive,
                finishedAt: Date()
            )
            self.lastResult = runResult
            self.status = .idle
        } catch {
            self.status = .error(error.localizedDescription)
        }
    }

    private func deviceID() -> String {
        if let v = UIDevice.current.identifierForVendor?.uuidString { return v }
        return UUID().uuidString
    }

    private func deviceModel() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        return withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }

    private func osVersion() -> String {
        "iOS \(UIDevice.current.systemVersion)"
    }

    private func appVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
}

extension JSONEncoder {
    static var deterministic: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return e
    }
}
