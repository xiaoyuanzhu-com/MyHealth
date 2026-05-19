import Foundation
import HealthKit
import UIKit

/// Orchestrates one day-by-day sync. A run has two phases:
///
///   1. Forward (oldest → newest): `[lastSyncedDay … today]`. Re-syncs the
///      anchor day to catch late-arriving data, then walks forward to today.
///      On first run (no anchor), starts from `oldestDataDay` probed from
///      HealthKit.
///
///   2. Double-check (backward, newest-of-old → oldest-of-old): 7 days
///      strictly older than the anchor. Catches edits/backfills to days the
///      previous run already covered. Skipped on first run.
///
/// For each day, iterate every sample type then workouts (one extra slot).
/// Per (day, type): query HealthKit with a day-bounded predicate, merge with
/// remote, upload. Memory is bounded to one (day, type) slice. Pause/abort
/// flags are honored at every (day, type) boundary.
///
/// On full completion: `cursor.lastSyncedDay = today`, run-state cleared.
/// Pause keeps state; abort deletes it; resume picks up at the saved
/// (completedDayIndex, inProgressTypeIndex).
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
        let currentTypeIndex: Int
        let totalTypes: Int
        let currentTypeName: String?
        let phase: SyncWindow.Phase?
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

    private let doubleCheckDays = 7

    static weak var currentlyActive: SyncCoordinator?

    init(reader: HealthKitReader = HealthKitReader()) {
        self.reader = reader
    }

    // MARK: - Public control surface

    func runOnce(enabledDestinations: Set<Destination>) async {
        Self.currentlyActive = self
        defer { if Self.currentlyActive === self { Self.currentlyActive = nil } }
        pauseRequested = false
        abortRequested = false
        if let existing = SyncRunStore.load() {
            print("MyHealth: resuming run id=\(existing.runID) at day \(existing.completedDayIndex)/\(existing.daysToSync.count) typeIndex=\(existing.inProgressTypeIndex)")
            await runLoop(state: existing, enabledDestinations: enabledDestinations)
        } else {
            await freshRun(enabledDestinations: enabledDestinations)
        }
    }

    func pause() { pauseRequested = true }
    func abort() { abortRequested = true }

    var hasPendingRun: Bool { SyncRunStore.load() != nil }

    // MARK: - Fresh run

    private func freshRun(enabledDestinations: Set<Destination>) async {
        let started = Date()
        let runID = makeRunID(date: started)
        do {
            let cursor = SyncCursor.load()
            let tz = TimeZone.current.identifier
            let today = DayBucketer.dayKey(start: started, timezone: TimeZone.current)
            let earliestPermitted = DayBucketer.dayKey(
                start: HKHealthStore().earliestPermittedSampleDate(),
                timezone: TimeZone.current
            )

            // First run only: probe HK for oldest sample to bound the back-fill.
            var oldestDataDay: DayBucketer.DayKey?
            if cursor.lastSyncedDay == nil {
                status = .running(stage: String(localized: "Finding earliest data"))
                oldestDataDay = await reader.oldestDataDay(timezone: TimeZone.current)
                print("MyHealth: first-run oldestDataDay=\(oldestDataDay?.date ?? "-")")
            }

            let days = SyncWindow.compute(
                today: today,
                cursor: cursor,
                oldestDataDay: oldestDataDay,
                doubleCheckDays: doubleCheckDays,
                earliestPermitted: earliestPermitted,
                timezone: tz
            )
            let forwardCount = days.filter { $0.phase == .forward }.count
            let doubleCheckCount = days.count - forwardCount
            print("MyHealth: window forward=\(forwardCount) doubleCheck=\(doubleCheckCount) " +
                  "start=\(days.first?.key.date ?? "-") end=\(days.last?.key.date ?? "-")")

            let state = SyncRunState(
                runID: runID,
                startedAt: SampleEncoder.iso(started),
                daysToSync: days,
                completedDayIndex: 0,
                inProgressTypeIndex: 0
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

        let deviceInfo = WorkoutFile.DeviceInfo(
            name: UIDevice.current.name,
            model: deviceModel(),
            systemVersion: UIDevice.current.systemVersion
        )

        let typeSequence = HealthDataTypes.allAnchoredSampleTypes
            .filter { !($0 is HKWorkoutType) }
        let workoutSlotIndex = typeSequence.count
        let totalSlots = workoutSlotIndex + 1

        var totalSamples = 0
        var totalWorkouts = 0

        do {
            for dayIdx in state.completedDayIndex..<state.daysToSync.count {
                if abortRequested {
                    print("MyHealth: aborting at day \(dayIdx)/\(state.daysToSync.count)")
                    SyncRunStore.clear()
                    self.status = .idle
                    self.progress = nil
                    return
                }
                if pauseRequested {
                    print("MyHealth: paused at day \(dayIdx)/\(state.daysToSync.count) typeIdx=\(state.inProgressTypeIndex)")
                    state.completedDayIndex = dayIdx
                    try SyncRunStore.save(state)
                    self.status = .paused(completedDays: dayIdx, totalDays: state.daysToSync.count)
                    self.progress = nil
                    return
                }

                let entry = state.daysToSync[dayIdx]
                let day = entry.key
                let phase = entry.phase
                // Resume mid-day only on the first outer-loop iteration of this run;
                // every subsequent day starts at slot 0 because the end-of-day save
                // (below) resets inProgressTypeIndex.
                let startTypeIdx = (dayIdx == state.completedDayIndex) ? state.inProgressTypeIndex : 0

                // Per-day status: a single "starting day X" update. We do NOT
                // re-update status for every type below — empty (day, type)
                // cells are microseconds of HK work, and re-publishing the
                // status N times forces N SwiftUI re-renders which is the
                // actual perceptual slowness. We only re-update when there
                // is real work to show (inside syncQuantity/syncCategory).
                self.status = .running(stage: stageString(phase: phase, day: day.date))
                self.progress = Progress(
                    completedDays: dayIdx, totalDays: state.daysToSync.count,
                    currentDate: day.date, currentTypeIndex: startTypeIdx,
                    totalTypes: totalSlots, currentTypeName: nil, phase: phase
                )

                for typeIdx in startTypeIdx..<totalSlots {
                    if abortRequested {
                        print("MyHealth: aborting mid-day at day \(dayIdx)/\(state.daysToSync.count) typeIdx=\(typeIdx)")
                        SyncRunStore.clear()
                        self.status = .idle
                        self.progress = nil
                        return
                    }
                    if pauseRequested {
                        state.completedDayIndex = dayIdx
                        state.inProgressTypeIndex = typeIdx
                        try SyncRunStore.save(state)
                        self.status = .paused(completedDays: dayIdx, totalDays: state.daysToSync.count)
                        return
                    }

                    let didWork: Bool
                    let displayName: String
                    if typeIdx == workoutSlotIndex {
                        displayName = String(localized: "Workouts")
                        let n = try await syncWorkouts(
                            day: day, deviceInfo: deviceInfo,
                            mld: mldClient, drive: drive
                        )
                        totalWorkouts += n
                        didWork = n > 0
                    } else {
                        let sampleType = typeSequence[typeIdx]
                        displayName = TypeNaming.displayName(for: sampleType.identifier)
                        if let q = sampleType as? HKQuantityType {
                            let outcome = try await syncQuantity(
                                day: day, type: q, phase: phase,
                                mld: mldClient, drive: drive
                            )
                            totalSamples += outcome.uploaded
                            didWork = outcome.didUpload
                        } else if let c = sampleType as? HKCategoryType {
                            let outcome = try await syncCategory(
                                day: day, type: c, phase: phase,
                                mld: mldClient, drive: drive
                            )
                            totalSamples += outcome.uploaded
                            didWork = outcome.didUpload
                        } else {
                            didWork = false
                        }
                    }

                    // Only refresh UI when this slot actually did something.
                    // Empty types don't tick the type label — they're invisible
                    // to the user and complete in microseconds.
                    if didWork {
                        self.status = .running(stage: stageString(
                            phase: phase, day: day.date, typeName: displayName
                        ))
                        self.progress = Progress(
                            completedDays: dayIdx, totalDays: state.daysToSync.count,
                            currentDate: day.date, currentTypeIndex: typeIdx,
                            totalTypes: totalSlots, currentTypeName: displayName,
                            phase: phase
                        )
                    }

                    state.completedDayIndex = dayIdx
                    state.inProgressTypeIndex = typeIdx + 1
                    try SyncRunStore.save(state)
                }

                state.completedDayIndex = dayIdx + 1
                state.inProgressTypeIndex = 0
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

    private func stageString(phase: SyncWindow.Phase, day: String, typeName: String? = nil) -> String {
        switch (phase, typeName) {
        case (.forward, .some(let t)):
            return String(localized: "Syncing \(day) · \(t)")
        case (.forward, nil):
            return String(localized: "Syncing \(day)")
        case (.doubleCheck, .some(let t)):
            return String(localized: "Double-checking updates for \(day) · \(t)")
        case (.doubleCheck, nil):
            return String(localized: "Double-checking updates for \(day)")
        }
    }

    private func finalize(state: SyncRunState, totalSamples: Int, totalWorkouts: Int,
                          mldUploaded: Bool, driveUploaded: Bool) async throws {
        // Anchor advances to the newest forward day seen, which by construction
        // is the latest `.forward` entry in `daysToSync`. If for some reason
        // no forward entry exists (degenerate), don't move the anchor.
        let newestForward = state.daysToSync
            .reversed()
            .first(where: { $0.phase == .forward })?
            .key
        if let newestForward {
            var cursor = SyncCursor.load()
            cursor.lastSyncedDay = newestForward
            try SyncCursor.save(cursor)
        }
        SyncRunStore.clear()
        let result = SyncRunResult(
            runID: state.runID,
            totalSamples: totalSamples,
            totalWorkouts: totalWorkouts,
            totalDays: state.daysToSync.count,
            myLifeDBUploaded: mldUploaded,
            driveUploaded: driveUploaded,
            finishedAt: Date()
        )
        self.lastResult = result
        self.status = .idle
        self.progress = nil
        print("MyHealth: sync done run=\(state.runID) samples=\(totalSamples) workouts=\(totalWorkouts) days=\(state.daysToSync.count) anchor=\(newestForward?.date ?? "-")")
    }

    // MARK: - Per-(day, type) slots

    private struct SlotOutcome {
        let uploaded: Int
        let didUpload: Bool
    }

    private func syncQuantity(
        day: DayBucketer.DayKey, type: HKQuantityType, phase: SyncWindow.Phase,
        mld: MyLifeDBClient?, drive: GoogleDriveClient?
    ) async throws -> SlotOutcome {
        let incoming = try await reader.readQuantity(type: type, day: day)
        if incoming.isEmpty { return SlotOutcome(uploaded: 0, didUpload: false) }
        let filename = TypeNaming.filename(for: type.identifier)
        let path = "\(day.pathPrefix)/\(filename)"
        let existing = try await getExistingQuantity(path: path, mld: mld, drive: drive)
        let merged = SnapshotMerger.merge(existing: existing, incoming: incoming)
        // Double-check optimization: if the merged content equals what is
        // already on the remote, skip the network PUT entirely.
        if phase == .doubleCheck, merged == existing {
            return SlotOutcome(uploaded: merged.count, didUpload: false)
        }
        let unit = merged.first?.unit ?? incoming.first?.unit ?? ""
        let envelope = DayFile.quantity(
            date: day.date, type: type.identifier, timezone: day.timezone,
            unit: unit, samples: merged
        )
        let body = try JSONEncoder.daySorted.encode(envelope)
        try await put(path: path, body: body, mld: mld, drive: drive)
        return SlotOutcome(uploaded: merged.count, didUpload: true)
    }

    private func syncCategory(
        day: DayBucketer.DayKey, type: HKCategoryType, phase: SyncWindow.Phase,
        mld: MyLifeDBClient?, drive: GoogleDriveClient?
    ) async throws -> SlotOutcome {
        let incoming = try await reader.readCategory(type: type, day: day)
        if incoming.isEmpty { return SlotOutcome(uploaded: 0, didUpload: false) }
        let filename = TypeNaming.filename(for: type.identifier)
        let path = "\(day.pathPrefix)/\(filename)"
        let existing = try await getExistingCategory(path: path, mld: mld, drive: drive)
        let merged = SnapshotMerger.mergeCategory(existing: existing, incoming: incoming)
        if phase == .doubleCheck, merged == existing {
            return SlotOutcome(uploaded: merged.count, didUpload: false)
        }
        let envelope = DayFile.category(
            date: day.date, type: type.identifier, timezone: day.timezone,
            samples: merged
        )
        let body = try JSONEncoder.daySorted.encode(envelope)
        try await put(path: path, body: body, mld: mld, drive: drive)
        return SlotOutcome(uploaded: merged.count, didUpload: true)
    }

    private func syncWorkouts(
        day: DayBucketer.DayKey, deviceInfo: WorkoutFile.DeviceInfo,
        mld: MyLifeDBClient?, drive: GoogleDriveClient?
    ) async throws -> Int {
        let workouts = try await reader.readWorkouts(day: day)
        var uploaded = 0
        for w in workouts {
            if abortRequested || pauseRequested { break }
            let route = (try? await reader.loadRoute(for: w)) ?? nil
            let wf = SampleEncoder.encode(w, events: w.workoutEvents, route: route, deviceInfo: deviceInfo)
            let filename = TypeNaming.workoutFilename(uuid: wf.uuid)
            let path = "\(day.pathPrefix)/\(filename)"
            let body = try JSONEncoder.daySorted.encode(wf)
            try await put(path: path, body: body, mld: mld, drive: drive)
            uploaded += 1
        }
        return uploaded
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
    static var daySorted: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return e
    }
}
