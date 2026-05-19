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
        // TODO(Task 8): rewrite this into the day-by-day pause/abort/resume loop.
        print("MyHealth: SyncCoordinator.runOnce is stubbed pending Task 8 rewrite")
        self.status = .idle
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
