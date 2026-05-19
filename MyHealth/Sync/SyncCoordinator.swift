import Foundation
import HealthKit
import UIKit

/// Orchestrates one day-by-day sync. Top-level flow:
///   1. Load anchors from AnchorStore.
///   2. Read new HealthKit samples, bucketed by local day.
///   3. Persist SyncRunState (so pause/kill is recoverable).
///   4. Walk days oldest→newest. For each (day, type):
///        GET existing remote → merge by UUID → PUT back.
///      Pause/abort flags are polled between files.
///   5. On full completion: advance anchors in AnchorStore, clear state.
///
/// Pause keeps state. Abort deletes it. Resume picks up where pause left off.
@MainActor
final class SyncCoordinator: ObservableObject {
    @Published private(set) var status: SyncStatus = .idle
    @Published private(set) var lastResult: SyncRunResult?
    @Published private(set) var progress: Progress?

    enum SyncStatus: Equatable {
        case idle
        case running(stage: String)
        case paused(completedDays: Int, totalDays: Int)
        case error(String)
    }

    struct Progress: Equatable {
        let completedDays: Int
        let totalDays: Int
        let currentDate: String?
    }

    struct SyncRunResult: Equatable {
        let runID: String
        let totalSamples: Int
        let totalWorkouts: Int
        let totalDays: Int
        let myLifeDBUploaded: Bool
        let driveUploaded: Bool
        let finishedAt: Date
    }

    enum Destination { case myLifeDB, googleDrive }

    private let reader: HealthKitReader
    private var pauseRequested = false
    private var abortRequested = false

    /// Most-recently-active coordinator, exposed so BackgroundSync (Task 10)
    /// can request a pause when iOS preempts the BG task.
    static weak var currentlyActive: SyncCoordinator?

    init(reader: HealthKitReader = HealthKitReader()) {
        self.reader = reader
    }

    // MARK: - Public control surface

    /// Starts a new sync, or resumes a paused one if state exists on disk.
    func runOnce(enabledDestinations: Set<Destination>) async {
        Self.currentlyActive = self
        defer { if Self.currentlyActive === self { Self.currentlyActive = nil } }
        pauseRequested = false
        abortRequested = false
        if let existing = SyncRunStore.load() {
            print("MyHealth: resuming run id=\(existing.runID) at day \(existing.completedDayCount)/\(existing.buckets.count)")
            await runLoop(state: existing, enabledDestinations: enabledDestinations)
        } else {
            await freshRun(enabledDestinations: enabledDestinations)
        }
    }

    /// Halts the sync at the next checkpoint and persists progress.
    func pause() { pauseRequested = true }

    /// Halts the sync at the next checkpoint and deletes state. Anchors do
    /// NOT advance.
    func abort() { abortRequested = true }

    /// True iff a partially-completed run exists on disk.
    var hasPendingRun: Bool { SyncRunStore.load() != nil }

    // MARK: - Fresh run

    private func freshRun(enabledDestinations: Set<Destination>) async {
        let started = Date()
        let runID = makeRunID(date: started)
        do {
            status = .running(stage: String(localized: "Loading anchors"))
            let priorAnchors = AnchorStore.loadCache()
            print("MyHealth: anchors loaded count=\(priorAnchors.count)")

            status = .running(stage: String(localized: "Reading HealthKit"))
            let deviceInfo = WorkoutFile.DeviceInfo(
                name: UIDevice.current.name,
                model: deviceModel(),
                systemVersion: UIDevice.current.systemVersion
            )
            let read = try await reader.readBucketed(anchors: priorAnchors, deviceInfo: deviceInfo)
            print("MyHealth: bucketed days=\(read.buckets.count) types=\(read.newAnchors.count)")

            let state = SyncRunState(
                runID: runID,
                startedAt: SampleEncoder.iso(started),
                anchorsAtStart: AnchorStore.encodeAll(priorAnchors),
                newAnchors: AnchorStore.encodeAll(read.newAnchors),
                buckets: read.buckets,
                completedDayCount: 0
            )
            try SyncRunStore.save(state)
            await runLoop(state: state, enabledDestinations: enabledDestinations)
        } catch {
            status = .error(error.localizedDescription)
            print("MyHealth: sync FAILED stage=fresh-run error=\(error.localizedDescription)")
        }
    }

    // MARK: - Day loop

    private func runLoop(state initialState: SyncRunState,
                         enabledDestinations: Set<Destination>) async {
        var state = initialState
        let mldSession: MyLifeDBSession? = enabledDestinations.contains(.myLifeDB)
            ? (try? TokenStore.load()) ?? nil : nil
        let mldClient: MyLifeDBClient? = mldSession.map { MyLifeDBClient(session: $0) }
        let driveAvailable = enabledDestinations.contains(.googleDrive) && DriveAuth.currentUser != nil
        let drive: GoogleDriveClient? = driveAvailable ? GoogleDriveClient() : nil

        var totalSamples = 0
        var totalWorkouts = 0

        do {
            for index in state.completedDayCount..<state.buckets.count {
                if abortRequested {
                    print("MyHealth: aborting at day \(index)/\(state.buckets.count)")
                    SyncRunStore.clear()
                    self.status = .idle
                    self.progress = nil
                    return
                }
                if pauseRequested {
                    print("MyHealth: paused at day \(index)/\(state.buckets.count)")
                    try SyncRunStore.save(state)
                    self.status = .paused(completedDays: index, totalDays: state.buckets.count)
                    self.progress = Progress(completedDays: index, totalDays: state.buckets.count, currentDate: nil)
                    return
                }

                let bucket = state.buckets[index]
                self.status = .running(stage: String(localized: "Uploading \(bucket.key.date)"))
                self.progress = Progress(completedDays: index, totalDays: state.buckets.count, currentDate: bucket.key.date)

                // Quantity files.
                for (type, wrapped) in bucket.quantitySamples {
                    if abortRequested || pauseRequested { break }
                    let filename = TypeNaming.filename(for: type)
                    let path = "\(bucket.key.pathPrefix)/\(filename)"
                    let samples = wrapped.map { $0.toSample() }
                    let unit = samples.first?.unit ?? ""
                    let merged = try await mergeAndUploadQuantity(
                        path: path, day: bucket.key, type: type, unit: unit,
                        incoming: samples, mld: mldClient, drive: drive
                    )
                    totalSamples += merged
                }

                // Category files.
                for (type, wrapped) in bucket.categorySamples {
                    if abortRequested || pauseRequested { break }
                    let filename = TypeNaming.filename(for: type)
                    let path = "\(bucket.key.pathPrefix)/\(filename)"
                    let samples = wrapped.map { $0.toSample() }
                    let merged = try await mergeAndUploadCategory(
                        path: path, day: bucket.key, type: type,
                        incoming: samples, mld: mldClient, drive: drive
                    )
                    totalSamples += merged
                }

                // Workouts — one file per workout, no merge needed.
                for w in bucket.workouts {
                    if abortRequested || pauseRequested { break }
                    let filename = TypeNaming.workoutFilename(uuid: w.uuid)
                    let path = "\(bucket.key.pathPrefix)/\(filename)"
                    let body = try JSONEncoder.daySorted.encode(w)
                    try await put(path: path, body: body, mld: mldClient, drive: drive)
                    totalWorkouts += 1
                }

                if abortRequested || pauseRequested { continue }

                state.completedDayCount = index + 1
                try SyncRunStore.save(state)
            }

            try await finalize(state: state, totalSamples: totalSamples, totalWorkouts: totalWorkouts,
                               mldUploaded: mldClient != nil, driveUploaded: drive != nil)
        } catch {
            try? SyncRunStore.save(state)
            self.status = .error(error.localizedDescription)
            print("MyHealth: sync FAILED stage=day-loop error=\(error.localizedDescription)")
        }
    }

    private func finalize(state: SyncRunState, totalSamples: Int, totalWorkouts: Int,
                          mldUploaded: Bool, driveUploaded: Bool) async throws {
        let newAnchors = AnchorStore.decodeAll(state.newAnchors)
        AnchorStore.saveCache(newAnchors)
        SyncRunStore.clear()
        let result = SyncRunResult(
            runID: state.runID,
            totalSamples: totalSamples,
            totalWorkouts: totalWorkouts,
            totalDays: state.buckets.count,
            myLifeDBUploaded: mldUploaded,
            driveUploaded: driveUploaded,
            finishedAt: Date()
        )
        self.lastResult = result
        self.status = .idle
        self.progress = nil
        print("MyHealth: sync done run=\(state.runID) samples=\(totalSamples) workouts=\(totalWorkouts) days=\(state.buckets.count)")
    }

    // MARK: - Merge + upload helpers

    private func mergeAndUploadQuantity(
        path: String, day: DayBucketer.DayKey, type: String, unit: String,
        incoming: [QuantitySample], mld: MyLifeDBClient?, drive: GoogleDriveClient?
    ) async throws -> Int {
        let existing = try await getExistingQuantity(path: path, mld: mld, drive: drive)
        let merged = SnapshotMerger.merge(existing: existing, incoming: incoming)
        let envelope = DayFile.quantity(
            date: day.date, type: type, timezone: day.timezone, unit: unit, samples: merged
        )
        let body = try JSONEncoder.daySorted.encode(envelope)
        try await put(path: path, body: body, mld: mld, drive: drive)
        return merged.count
    }

    private func mergeAndUploadCategory(
        path: String, day: DayBucketer.DayKey, type: String,
        incoming: [CategorySample], mld: MyLifeDBClient?, drive: GoogleDriveClient?
    ) async throws -> Int {
        let existing = try await getExistingCategory(path: path, mld: mld, drive: drive)
        let merged = SnapshotMerger.mergeCategory(existing: existing, incoming: incoming)
        let envelope = DayFile.category(
            date: day.date, type: type, timezone: day.timezone, samples: merged
        )
        let body = try JSONEncoder.daySorted.encode(envelope)
        try await put(path: path, body: body, mld: mld, drive: drive)
        return merged.count
    }

    private func getExistingQuantity(path: String, mld: MyLifeDBClient?, drive: GoogleDriveClient?) async throws -> [QuantitySample] {
        if let mld, let data = try await mld.getFile(relativePath: path),
           let decoded = try? JSONDecoder().decode(DayFile<QuantitySample>.self, from: data) {
            return decoded.samples
        }
        if let drive, let data = try await drive.getFile(relativePath: path),
           let decoded = try? JSONDecoder().decode(DayFile<QuantitySample>.self, from: data) {
            return decoded.samples
        }
        return []
    }

    private func getExistingCategory(path: String, mld: MyLifeDBClient?, drive: GoogleDriveClient?) async throws -> [CategorySample] {
        if let mld, let data = try await mld.getFile(relativePath: path),
           let decoded = try? JSONDecoder().decode(DayFile<CategorySample>.self, from: data) {
            return decoded.samples
        }
        if let drive, let data = try await drive.getFile(relativePath: path),
           let decoded = try? JSONDecoder().decode(DayFile<CategorySample>.self, from: data) {
            return decoded.samples
        }
        return []
    }

    private func put(path: String, body: Data, mld: MyLifeDBClient?, drive: GoogleDriveClient?) async throws {
        if let mld {
            try await mld.putBytes(relativePath: path, body: body, contentType: "application/json")
        }
        if let drive {
            try await drive.uploadBytes(relativePath: path, body: body)
        }
    }

    // MARK: - misc

    private func makeRunID(date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    private func deviceModel() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        return withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }
}

extension JSONEncoder {
    /// Deterministic JSON for day files: sorted keys, pretty-printed (so the
    /// remote files are diff-friendly), no escaped slashes.
    static var daySorted: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return e
    }

    /// Kept for backward compatibility: used in ManifestTests.swift.
    static var deterministic: JSONEncoder { daySorted }
}
