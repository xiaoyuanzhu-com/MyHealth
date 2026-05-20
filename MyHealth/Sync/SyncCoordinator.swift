import Foundation
import HealthKit
import UIKit

/// Orchestrates one sync run with a single unified flow:
///
///   1. Backward walk to find the start day. Begin at the anchor (or
///      today if no anchor). For each day, check whether the locally-
///      stored fingerprint still matches HealthKit's content. Match ⇒
///      wall found, the next day is the start. Mismatch ⇒ walk back one
///      day and check again. On first sync the fingerprint store is
///      empty, so the check degrades to "does this day have any sample
///      at all?" and the walk terminates at the first empty day.
///
///   2. Forward sync from `start` to today, oldest → newest. Each day's
///      types are processed in a bounded TaskGroup so HealthKit reads
///      and remote PUTs run concurrently; memory stays bounded to
///      `maxConcurrentSlotsPerDay` (day, type) slices in flight. Days
///      strictly newer than the previous run's anchor skip the GET
///      against the remote — those files don't exist yet, so the
///      round-trip would only return 404. After each day completes,
///      the day's freshly-computed hash is stored.
///
///   3. On full completion: `cursor.lastSyncedDay = today`, run-state
///      cleared. The walk-back state is not persisted; if the run is
///      paused or aborted before forward sync begins, the next start
///      simply re-runs the walk (cheap in the steady state). A run
///      stopped mid-day resumes from the start of that day on the
///      next run — uploads are idempotent thanks to the merge step.
@MainActor
final class SyncCoordinator: ObservableObject {
    @Published private(set) var status: SyncStatus = .idle
    @Published private(set) var lastResult: SyncRunResult?
    @Published private(set) var progress: Progress?

    enum SyncStatus: Equatable {
        case idle
        case running(stage: String)
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
        let webdavUploaded: Bool
        let finishedAt: Date
    }

    enum Destination { case myLifeDB, googleDrive, webdav }

    private let reader: HealthKitReader
    private var stopRequested = false
    /// Set when the stop was triggered by the app moving to background, not
    /// by the user tapping Stop. Used by the day-loop's catch to suppress
    /// the error banner for the inevitable URLSession-cancelled /
    /// "Protected health data is inaccessible" throws that follow.
    private var pausedByBackgrounding = false

    /// Upper bound on (day, type) slots in flight at once within a single day.
    /// Each in-flight slot holds one `(day, type)` slice plus its remote
    /// round-trip; this also caps memory and HealthKit/network pressure.
    private static let maxConcurrentSlotsPerDay = 8

    static weak var currentlyActive: SyncCoordinator?

    init(reader: HealthKitReader = HealthKitReader()) {
        self.reader = reader
    }

    // MARK: - Public control surface

    func runOnce(enabledDestinations: Set<Destination>) async {
        Self.currentlyActive = self
        defer { if Self.currentlyActive === self { Self.currentlyActive = nil } }
        stopRequested = false
        pausedByBackgrounding = false
        if let existing = SyncRunStore.load() {
            print("MyHealth: resuming run id=\(existing.runID) at day \(existing.completedDayIndex)/\(existing.daysToSync.count) typeIndex=\(existing.inProgressTypeIndex)")
            await runLoop(state: existing, enabledDestinations: enabledDestinations)
        } else {
            await freshRun(enabledDestinations: enabledDestinations)
        }
    }

    /// Halts the sync at the next (day, type) boundary and persists progress.
    /// The next `runOnce` resumes from the saved checkpoint. Days fully
    /// uploaded so far stay uploaded; their fingerprints are kept in
    /// day-hashes.json so future runs can skip them quickly via the walk-back.
    func stop() { stopRequested = true }

    /// Like `stop()`, but flags the teardown as a background-triggered pause
    /// so the catch block knows to treat the resulting URLSession /
    /// HealthKit errors as expected rather than surfacing them as an error
    /// banner. Called from `MyHealthApp` when scenePhase becomes
    /// `.background` while a run is active.
    func pauseForBackgrounding() {
        guard case .running = status else { return }
        pausedByBackgrounding = true
        stopRequested = true
        print("MyHealth: pausing sync — app moved to background")
    }

    var hasPendingRun: Bool { SyncRunStore.load() != nil }

    /// Brief summary of the pending (stopped) run, if any. Used by the UI's
    /// idle-state status line.
    struct PendingRunSummary: Equatable {
        let completedDays: Int
        let totalDays: Int
    }
    var pendingRunSummary: PendingRunSummary? {
        guard let s = SyncRunStore.load() else { return nil }
        return PendingRunSummary(completedDays: s.completedDayIndex, totalDays: s.daysToSync.count)
    }

    // MARK: - Fresh run: walk back, then plan forward sync

    private func freshRun(enabledDestinations: Set<Destination>) async {
        let started = Date()
        let runID = makeRunID(date: started)
        do {
            let cursor = SyncCursor.load()
            let hashes = DayHashStore.load()
            let today = DayBucketer.dayKey(start: started, timezone: TimeZone.current)
            let earliestPermitted = DayBucketer.dayKey(
                start: HKHealthStore().earliestPermittedSampleDate(),
                timezone: TimeZone.current
            )

            // 1) Backward walk to discover the start day.
            status = .running(stage: String(localized: "Checking for updates"))
            self.progress = nil
            let start = await discoverStartDay(
                anchor: cursor.lastSyncedDay,
                today: today,
                earliestPermitted: earliestPermitted,
                hashes: hashes
            )
            // If the user tapped Stop during the walk, bail before allocating
            // a run state.
            if stopRequested {
                self.status = .idle
                return
            }

            // 2) Plan forward sync.
            let days = daysInRange(from: start, through: today)
            print("MyHealth: walk done start=\(start.date) today=\(today.date) days=\(days.count)")

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
            if pausedByBackgrounding {
                self.status = .idle
                self.progress = nil
                print("MyHealth: sync paused by backgrounding during fresh-run setup")
            } else {
                status = .error(error.localizedDescription)
                print("MyHealth: sync FAILED stage=fresh-run error=\(error.localizedDescription)")
            }
        }
    }

    /// Walk backward from `anchor` (or today if no anchor) until either
    /// the day's content matches the stored fingerprint (wall found) or
    /// the day has no samples and no stored fingerprint (empty-history
    /// wall). Returns the first day that the forward sync should start at.
    private func discoverStartDay(
        anchor: DayBucketer.DayKey?,
        today: DayBucketer.DayKey,
        earliestPermitted: DayBucketer.DayKey,
        hashes: [String: String]
    ) async -> DayBucketer.DayKey {
        let dayMath = DayMath(timezone: today.timezone)
        var cursor = anchor ?? today
        while cursor.date >= earliestPermitted.date {
            if stopRequested {
                // Walk-back is not resumable — on next start we re-walk.
                // Return today as a safe default; the caller's stop check
                // will fire before any sync happens.
                return today
            }
            self.status = .running(stage: String(localized: "Checking for updates · \(cursor.date)"))
            let hasUpdates = await hasUpdates(day: cursor, storedHash: hashes[cursor.date])
            if hasUpdates {
                cursor = dayMath.previousDay(cursor)
            } else {
                return dayMath.nextDay(cursor)
            }
        }
        return earliestPermitted
    }

    private func hasUpdates(day: DayBucketer.DayKey, storedHash: String?) async -> Bool {
        if let storedHash {
            // We have a record of this day. Recompute and compare.
            guard let live = try? await reader.dayHash(day: day) else {
                // HK threw on a non-auth error; safest to assume updates exist
                // so the day gets re-uploaded.
                return true
            }
            return live != storedHash
        } else {
            // First-time encounter with this day. Fast probe: any sample?
            return await reader.dayHasAnySample(day: day)
        }
    }

    private func daysInRange(
        from start: DayBucketer.DayKey,
        through end: DayBucketer.DayKey
    ) -> [DayBucketer.DayKey] {
        guard start.date <= end.date else { return [] }
        let dayMath = DayMath(timezone: end.timezone)
        var out: [DayBucketer.DayKey] = []
        var c = start
        let cap = 50_000  // safety against pathological inputs
        var i = 0
        while c.date <= end.date {
            out.append(c)
            if c.date == end.date { break }
            c = dayMath.nextDay(c)
            i += 1
            if i >= cap { break }
        }
        return out
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
        let webdavCreds: WebDAVCredentials? = enabledDestinations.contains(.webdav)
            ? WebDAVStore.load() : nil
        let webdav: WebDAVClient? = webdavCreds.map { WebDAVClient(credentials: $0) }

        let deviceInfo = WorkoutFile.DeviceInfo(
            name: UIDevice.current.name,
            model: deviceModel(),
            systemVersion: UIDevice.current.systemVersion
        )

        let typeSequence = HealthDataTypes.allAnchoredSampleTypes
            .filter { !($0 is HKWorkoutType) }
        let workoutSlotIndex = typeSequence.count
        let totalSlots = workoutSlotIndex + 1

        // Days strictly newer than the previous run's anchor have never been
        // uploaded — their remote file is guaranteed absent, so the GET that
        // the merge step would issue can be skipped. Days at-or-before the
        // anchor were either uploaded by a previous run or got re-included
        // by the walk-back; for those we still GET to merge with whatever
        // is remote. `cursor.lastSyncedDay` is read here (not at run start)
        // so resumed runs pick up the same anchor — `finalize` is the only
        // thing that advances the cursor.
        let previousAnchorDate: String? = SyncCursor.load().lastSyncedDay?.date

        var totalSamples = 0
        var totalWorkouts = 0

        do {
            for dayIdx in state.completedDayIndex..<state.daysToSync.count {
                if stopRequested {
                    print("MyHealth: stopped at day \(dayIdx)/\(state.daysToSync.count)")
                    state.completedDayIndex = dayIdx
                    state.inProgressTypeIndex = 0
                    try SyncRunStore.save(state)
                    self.status = .idle
                    self.progress = nil
                    return
                }

                let day = state.daysToSync[dayIdx]
                let skipExistingFetch: Bool = {
                    guard let prev = previousAnchorDate else { return true }
                    return day.date > prev
                }()

                self.status = .running(stage: String(localized: "Syncing \(day.date)"))
                self.progress = Progress(
                    completedDays: dayIdx, totalDays: state.daysToSync.count,
                    currentDate: day.date, currentTypeIndex: 0,
                    totalTypes: totalSlots, currentTypeName: nil
                )

                let outcome = try await runDayParallel(
                    day: day,
                    dayIdx: dayIdx,
                    totalDays: state.daysToSync.count,
                    typeSequence: typeSequence,
                    workoutSlotIndex: workoutSlotIndex,
                    totalSlots: totalSlots,
                    skipExistingFetch: skipExistingFetch,
                    deviceInfo: deviceInfo,
                    mld: mldClient, drive: drive, webdav: webdav
                )
                totalSamples += outcome.samples
                totalWorkouts += outcome.workouts

                if stopRequested {
                    print("MyHealth: stopped mid-day at day \(dayIdx)/\(state.daysToSync.count) — day will be retried on next run")
                    state.completedDayIndex = dayIdx
                    state.inProgressTypeIndex = 0
                    try SyncRunStore.save(state)
                    self.status = .idle
                    self.progress = nil
                    return
                }

                // Day completed: compute and store its fingerprint so future
                // walk-backs can compare. We hash AFTER upload because the
                // hash represents the local HK state at the time of sync;
                // any later HK change will not match.
                if let hash = try? await reader.dayHash(day: day) {
                    var hashes = DayHashStore.load()
                    hashes[day.date] = hash
                    try? DayHashStore.save(hashes)
                }

                state.completedDayIndex = dayIdx + 1
                state.inProgressTypeIndex = 0
                try SyncRunStore.save(state)
            }

            try await finalize(state: state, totalSamples: totalSamples, totalWorkouts: totalWorkouts,
                               mldUploaded: mldClient != nil, driveUploaded: drive != nil,
                               webdavUploaded: webdav != nil)
        } catch {
            try? SyncRunStore.save(state)
            if pausedByBackgrounding {
                // Expected fallout from the app being suspended mid-run
                // (URLSession cancelled, HealthKit locked, etc). State is
                // checkpointed; resume on next foreground run.
                self.status = .idle
                self.progress = nil
                print("MyHealth: sync paused by backgrounding mid-day — will resume on next run")
            } else {
                self.status = .error(error.localizedDescription)
                print("MyHealth: sync FAILED stage=day-loop error=\(error.localizedDescription)")
            }
        }
    }

    // MARK: - Per-day parallel slot execution

    private struct DayOutcome {
        var samples: Int = 0
        var workouts: Int = 0
    }

    private struct SlotResult {
        let samples: Int
        let workouts: Int
        let didWork: Bool
        let displayName: String
    }

    /// Runs all `totalSlots` slots for a single day with bounded concurrency.
    /// Slots are independent (different files, different HK types), so
    /// running them in parallel is safe; the bound keeps memory and
    /// HK/network pressure in check. Any thrown error from a slot cancels
    /// the rest of the day and propagates out to the day-loop's catch.
    private func runDayParallel(
        day: DayBucketer.DayKey,
        dayIdx: Int,
        totalDays: Int,
        typeSequence: [HKSampleType],
        workoutSlotIndex: Int,
        totalSlots: Int,
        skipExistingFetch: Bool,
        deviceInfo: WorkoutFile.DeviceInfo,
        mld: MyLifeDBClient?, drive: GoogleDriveClient?, webdav: WebDAVClient?
    ) async throws -> DayOutcome {
        var outcome = DayOutcome()
        var completed = 0

        try await withThrowingTaskGroup(of: SlotResult.self) { group in
            var nextSlot = 0
            var inFlight = 0
            let cap = Self.maxConcurrentSlotsPerDay

            func addOne() {
                let slotIdx = nextSlot
                nextSlot += 1
                inFlight += 1
                group.addTask { [self] in
                    try await runSlot(
                        slotIdx: slotIdx, day: day,
                        typeSequence: typeSequence,
                        workoutSlotIndex: workoutSlotIndex,
                        skipExistingFetch: skipExistingFetch,
                        deviceInfo: deviceInfo,
                        mld: mld, drive: drive, webdav: webdav
                    )
                }
            }

            while nextSlot < totalSlots && inFlight < cap {
                addOne()
            }

            while let r = try await group.next() {
                inFlight -= 1
                outcome.samples += r.samples
                outcome.workouts += r.workouts
                completed += 1

                if r.didWork {
                    self.status = .running(stage: String(localized: "Syncing \(day.date) · \(r.displayName)"))
                }
                self.progress = Progress(
                    completedDays: dayIdx, totalDays: totalDays,
                    currentDate: day.date,
                    currentTypeIndex: completed - 1,
                    totalTypes: totalSlots,
                    currentTypeName: r.didWork ? r.displayName : nil
                )

                if stopRequested {
                    group.cancelAll()
                } else if nextSlot < totalSlots {
                    addOne()
                }
            }
        }
        return outcome
    }

    /// One (day, type) slot. Pure dispatch — picks the right slot helper
    /// based on the type's Swift class. Safe to run concurrently with other
    /// slots: HKHealthStore and the destination clients tolerate concurrent
    /// requests, and each slot only touches its own file path.
    private func runSlot(
        slotIdx: Int, day: DayBucketer.DayKey,
        typeSequence: [HKSampleType], workoutSlotIndex: Int,
        skipExistingFetch: Bool, deviceInfo: WorkoutFile.DeviceInfo,
        mld: MyLifeDBClient?, drive: GoogleDriveClient?, webdav: WebDAVClient?
    ) async throws -> SlotResult {
        if slotIdx == workoutSlotIndex {
            let n = try await syncWorkouts(
                day: day, deviceInfo: deviceInfo,
                mld: mld, drive: drive, webdav: webdav
            )
            return SlotResult(samples: 0, workouts: n, didWork: n > 0,
                              displayName: String(localized: "Workouts"))
        }
        let sampleType = typeSequence[slotIdx]
        let displayName = TypeNaming.displayName(for: sampleType.identifier)
        if let q = sampleType as? HKQuantityType {
            let o = try await syncQuantity(
                day: day, type: q, skipExistingFetch: skipExistingFetch,
                mld: mld, drive: drive, webdav: webdav
            )
            return SlotResult(samples: o.uploaded, workouts: 0,
                              didWork: o.didUpload, displayName: displayName)
        }
        if let c = sampleType as? HKCategoryType {
            let o = try await syncCategory(
                day: day, type: c, skipExistingFetch: skipExistingFetch,
                mld: mld, drive: drive, webdav: webdav
            )
            return SlotResult(samples: o.uploaded, workouts: 0,
                              didWork: o.didUpload, displayName: displayName)
        }
        return SlotResult(samples: 0, workouts: 0, didWork: false,
                          displayName: displayName)
    }

    private func finalize(state: SyncRunState, totalSamples: Int, totalWorkouts: Int,
                          mldUploaded: Bool, driveUploaded: Bool, webdavUploaded: Bool) async throws {
        // Anchor advances to the newest day we covered. The forward plan is
        // oldest → newest, so the last entry is the freshest day. If the plan
        // is empty (clock skew / degenerate) the anchor stays put.
        if let newest = state.daysToSync.last {
            var cursor = SyncCursor.load()
            cursor.lastSyncedDay = newest
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
            webdavUploaded: webdavUploaded,
            finishedAt: Date()
        )
        self.lastResult = result
        self.status = .idle
        self.progress = nil
        print("MyHealth: sync done run=\(state.runID) samples=\(totalSamples) workouts=\(totalWorkouts) days=\(state.daysToSync.count) anchor=\(state.daysToSync.last?.date ?? "-")")
    }

    // MARK: - Per-(day, type) slots

    private struct SlotOutcome {
        let uploaded: Int
        let didUpload: Bool
    }

    private func syncQuantity(
        day: DayBucketer.DayKey, type: HKQuantityType, skipExistingFetch: Bool,
        mld: MyLifeDBClient?, drive: GoogleDriveClient?, webdav: WebDAVClient?
    ) async throws -> SlotOutcome {
        let incoming = try await reader.readQuantity(type: type, day: day)
        if incoming.isEmpty { return SlotOutcome(uploaded: 0, didUpload: false) }
        let filename = TypeNaming.filename(for: type.identifier)
        let path = "\(day.pathPrefix)/\(filename)"
        let existing: [QuantitySample] = skipExistingFetch
            ? []
            : try await getExistingQuantity(path: path, mld: mld, drive: drive, webdav: webdav)
        let merged = SnapshotMerger.merge(existing: existing, incoming: incoming)
        // If the merged content equals what is already on the remote, skip
        // the network PUT. This is the steady-state fast path: re-syncing a
        // day with no changes does no network work.
        if merged == existing {
            return SlotOutcome(uploaded: merged.count, didUpload: false)
        }
        let unit = merged.first?.unit ?? incoming.first?.unit ?? ""
        let envelope = DayFile.quantity(
            date: day.date, type: type.identifier, timezone: day.timezone,
            unit: unit, samples: merged
        )
        let body = try JSONEncoder.daySorted.encode(envelope)
        try await put(path: path, body: body, mld: mld, drive: drive, webdav: webdav)
        return SlotOutcome(uploaded: merged.count, didUpload: true)
    }

    private func syncCategory(
        day: DayBucketer.DayKey, type: HKCategoryType, skipExistingFetch: Bool,
        mld: MyLifeDBClient?, drive: GoogleDriveClient?, webdav: WebDAVClient?
    ) async throws -> SlotOutcome {
        let incoming = try await reader.readCategory(type: type, day: day)
        if incoming.isEmpty { return SlotOutcome(uploaded: 0, didUpload: false) }
        let filename = TypeNaming.filename(for: type.identifier)
        let path = "\(day.pathPrefix)/\(filename)"
        let existing: [CategorySample] = skipExistingFetch
            ? []
            : try await getExistingCategory(path: path, mld: mld, drive: drive, webdav: webdav)
        let merged = SnapshotMerger.mergeCategory(existing: existing, incoming: incoming)
        if merged == existing {
            return SlotOutcome(uploaded: merged.count, didUpload: false)
        }
        let envelope = DayFile.category(
            date: day.date, type: type.identifier, timezone: day.timezone,
            samples: merged
        )
        let body = try JSONEncoder.daySorted.encode(envelope)
        try await put(path: path, body: body, mld: mld, drive: drive, webdav: webdav)
        return SlotOutcome(uploaded: merged.count, didUpload: true)
    }

    private func syncWorkouts(
        day: DayBucketer.DayKey, deviceInfo: WorkoutFile.DeviceInfo,
        mld: MyLifeDBClient?, drive: GoogleDriveClient?, webdav: WebDAVClient?
    ) async throws -> Int {
        let workouts = try await reader.readWorkouts(day: day)
        var uploaded = 0
        for w in workouts {
            if stopRequested { break }
            let route = (try? await reader.loadRoute(for: w)) ?? nil
            let wf = SampleEncoder.encode(w, events: w.workoutEvents, route: route, deviceInfo: deviceInfo)
            let filename = TypeNaming.workoutFilename(uuid: wf.uuid)
            let path = "\(day.pathPrefix)/\(filename)"
            let body = try JSONEncoder.daySorted.encode(wf)
            try await put(path: path, body: body, mld: mld, drive: drive, webdav: webdav)
            uploaded += 1
        }
        return uploaded
    }

    private func getExistingQuantity(path: String, mld: MyLifeDBClient?, drive: GoogleDriveClient?, webdav: WebDAVClient?) async throws -> [QuantitySample] {
        if let mld, let data = try await mld.getFile(relativePath: path),
           let decoded = try? JSONDecoder().decode(DayFile<QuantitySample>.self, from: data) {
            return decoded.samples
        }
        if let drive, let data = try await drive.getFile(relativePath: path),
           let decoded = try? JSONDecoder().decode(DayFile<QuantitySample>.self, from: data) {
            return decoded.samples
        }
        if let webdav, let data = try await webdav.getFile(relativePath: path),
           let decoded = try? JSONDecoder().decode(DayFile<QuantitySample>.self, from: data) {
            return decoded.samples
        }
        return []
    }

    private func getExistingCategory(path: String, mld: MyLifeDBClient?, drive: GoogleDriveClient?, webdav: WebDAVClient?) async throws -> [CategorySample] {
        if let mld, let data = try await mld.getFile(relativePath: path),
           let decoded = try? JSONDecoder().decode(DayFile<CategorySample>.self, from: data) {
            return decoded.samples
        }
        if let drive, let data = try await drive.getFile(relativePath: path),
           let decoded = try? JSONDecoder().decode(DayFile<CategorySample>.self, from: data) {
            return decoded.samples
        }
        if let webdav, let data = try await webdav.getFile(relativePath: path),
           let decoded = try? JSONDecoder().decode(DayFile<CategorySample>.self, from: data) {
            return decoded.samples
        }
        return []
    }

    private func put(path: String, body: Data, mld: MyLifeDBClient?, drive: GoogleDriveClient?, webdav: WebDAVClient?) async throws {
        if let mld {
            try await mld.putBytes(relativePath: path, body: body, contentType: "application/json")
        }
        if let drive {
            try await drive.uploadBytes(relativePath: path, body: body)
        }
        if let webdav {
            try await webdav.uploadBytes(relativePath: path, body: body)
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

/// Local date arithmetic for a fixed timezone — reusable inside
/// `SyncCoordinator` for the walk-back and forward-range steps.
private struct DayMath {
    let calendar: Calendar
    let formatter: DateFormatter
    let timezone: String

    init(timezone: String) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: timezone) ?? .current
        self.calendar = cal
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.dateFormat = "yyyy-MM-dd"
        self.formatter = f
        self.timezone = timezone
    }

    func previousDay(_ k: DayBucketer.DayKey) -> DayBucketer.DayKey { shifted(k, by: -1) }
    func nextDay(_ k: DayBucketer.DayKey) -> DayBucketer.DayKey { shifted(k, by: 1) }

    private func shifted(_ k: DayBucketer.DayKey, by days: Int) -> DayBucketer.DayKey {
        guard let date = formatter.date(from: k.date),
              let moved = calendar.date(byAdding: .day, value: days, to: date)
        else { return k }
        return DayBucketer.DayKey(date: formatter.string(from: moved), timezone: timezone)
    }
}

extension JSONEncoder {
    static var daySorted: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return e
    }
}
