import Foundation
import HealthKit
import UIKit

/// Orchestrates one day-by-day sync. Top-level flow:
///   1. Load persistent SyncCursor.
///   2. Compute daysToSync (newest-first) from cursor + today + window policy.
///   3. Persist SyncRunState (just the day list + cursors — no samples).
///   4. Walk daysToSync, for each day iterate every sample type:
///        HKSampleQuery(type, day-predicate) → merge with remote → PUT.
///      Then workouts → upload one file per workout.
///      Pause/abort flags are polled between every (day, type) boundary.
///   5. On full completion: advance SyncCursor, clear SyncRunState.
///
/// Pause keeps state. Abort deletes it. Resume picks up at the saved
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

    private let recentReSyncDays = 7
    private let backfillChunkDays = 30

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
            status = .running(stage: String(localized: "Preparing sync"))
            let cursor = SyncCursor.load()
            let tz = TimeZone.current.identifier
            let today = DayBucketer.dayKey(start: started, timezone: TimeZone.current)
            let earliestPermitted = DayBucketer.dayKey(
                start: HKHealthStore().earliestPermittedSampleDate(),
                timezone: TimeZone.current
            )
            let days = SyncWindow.compute(
                today: today,
                cursor: cursor,
                earliestPermitted: earliestPermitted,
                recentReSyncDays: recentReSyncDays,
                backfillChunkDays: backfillChunkDays,
                timezone: tz
            )
            print("MyHealth: window computed days=\(days.count) newest=\(days.first?.date ?? "-") oldest=\(days.last?.date ?? "-")")

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

        // Per-day type sequence: every anchored sample type EXCEPT the
        // workout type (workouts are handled as one extra slot after types).
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
                    self.progress = Progress(
                        completedDays: dayIdx, totalDays: state.daysToSync.count,
                        currentDate: nil, currentTypeIndex: state.inProgressTypeIndex,
                        totalTypes: totalSlots, currentTypeName: nil
                    )
                    return
                }

                let day = state.daysToSync[dayIdx]
                // Resume mid-day only on the first outer-loop iteration of this run;
                // every subsequent day starts at slot 0 because the end-of-day save
                // (below) resets inProgressTypeIndex.
                let startTypeIdx = (dayIdx == state.completedDayIndex) ? state.inProgressTypeIndex : 0

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
                        self.progress = Progress(
                            completedDays: dayIdx, totalDays: state.daysToSync.count,
                            currentDate: day.date, currentTypeIndex: typeIdx,
                            totalTypes: totalSlots, currentTypeName: nil
                        )
                        return
                    }

                    if typeIdx == workoutSlotIndex {
                        let displayName = String(localized: "Workouts")
                        self.status = .running(stage: String(localized: "Syncing \(day.date) · \(displayName)"))
                        self.progress = Progress(
                            completedDays: dayIdx, totalDays: state.daysToSync.count,
                            currentDate: day.date, currentTypeIndex: typeIdx,
                            totalTypes: totalSlots, currentTypeName: displayName
                        )
                        let n = try await syncWorkouts(day: day, deviceInfo: deviceInfo, mld: mldClient, drive: drive)
                        totalWorkouts += n
                    } else {
                        let sampleType = typeSequence[typeIdx]
                        let displayName = TypeNaming.displayName(for: sampleType.identifier)
                        self.status = .running(stage: String(localized: "Syncing \(day.date) · \(displayName)"))
                        self.progress = Progress(
                            completedDays: dayIdx, totalDays: state.daysToSync.count,
                            currentDate: day.date, currentTypeIndex: typeIdx,
                            totalTypes: totalSlots, currentTypeName: displayName
                        )
                        if let q = sampleType as? HKQuantityType {
                            let n = try await syncQuantity(day: day, type: q, mld: mldClient, drive: drive)
                            totalSamples += n
                        } else if let c = sampleType as? HKCategoryType {
                            let n = try await syncCategory(day: day, type: c, mld: mldClient, drive: drive)
                            totalSamples += n
                        }
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

    private func finalize(state: SyncRunState, totalSamples: Int, totalWorkouts: Int,
                          mldUploaded: Bool, driveUploaded: Bool) async throws {
        var cursor = SyncCursor.load()
        cursor.advance(coveredDays: state.daysToSync)
        try SyncCursor.save(cursor)
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
        print("MyHealth: sync done run=\(state.runID) samples=\(totalSamples) workouts=\(totalWorkouts) days=\(state.daysToSync.count)")
    }

    // MARK: - Per-(day, type) slots

    private func syncQuantity(
        day: DayBucketer.DayKey, type: HKQuantityType,
        mld: MyLifeDBClient?, drive: GoogleDriveClient?
    ) async throws -> Int {
        let incoming = try await reader.readQuantity(type: type, day: day)
        if incoming.isEmpty { return 0 }
        let filename = TypeNaming.filename(for: type.identifier)
        let path = "\(day.pathPrefix)/\(filename)"
        let existing = try await getExistingQuantity(path: path, mld: mld, drive: drive)
        let merged = SnapshotMerger.merge(existing: existing, incoming: incoming)
        let unit = merged.first?.unit ?? incoming.first?.unit ?? ""
        let envelope = DayFile.quantity(
            date: day.date, type: type.identifier, timezone: day.timezone,
            unit: unit, samples: merged
        )
        let body = try JSONEncoder.daySorted.encode(envelope)
        try await put(path: path, body: body, mld: mld, drive: drive)
        return merged.count
    }

    private func syncCategory(
        day: DayBucketer.DayKey, type: HKCategoryType,
        mld: MyLifeDBClient?, drive: GoogleDriveClient?
    ) async throws -> Int {
        let incoming = try await reader.readCategory(type: type, day: day)
        if incoming.isEmpty { return 0 }
        let filename = TypeNaming.filename(for: type.identifier)
        let path = "\(day.pathPrefix)/\(filename)"
        let existing = try await getExistingCategory(path: path, mld: mld, drive: drive)
        let merged = SnapshotMerger.mergeCategory(existing: existing, incoming: incoming)
        let envelope = DayFile.category(
            date: day.date, type: type.identifier, timezone: day.timezone,
            samples: merged
        )
        let body = try JSONEncoder.daySorted.encode(envelope)
        try await put(path: path, body: body, mld: mld, drive: drive)
        return merged.count
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
