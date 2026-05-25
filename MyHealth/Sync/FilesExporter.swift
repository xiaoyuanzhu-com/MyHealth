import Foundation
import HealthKit
import UIKit
import ZIPFoundation

/// One-shot full-export pipeline for the Files-app target. Walks every day
/// from HealthKit's earliest permitted sample date through today, writes
/// each `DayFile` JSON into a temp directory mirroring the same
/// `apple-health/YYYY/MM/DD/<filename>.json` layout used by the remote
/// targets, then zips the tree and surfaces the URL for `UIDocumentPicker`
/// to hand to the user.
///
/// Unlike `SyncCoordinator`, this exporter has no anchor, no per-day hash
/// store, no merge step, and no resume. Every invocation is a complete
/// fresh export — the user controls when to run it and where to save the
/// resulting zip.
@MainActor
final class FilesExporter: ObservableObject {
    @Published private(set) var status: Status = .idle
    @Published private(set) var progress: Progress?
    @Published private(set) var lastExportAt: Date?
    /// Set when an export finishes successfully. The detail view binds a
    /// `.sheet(item:)` to this and presents the document-picker bridge.
    @Published var pendingExportURL: ExportArtifact?

    enum Status: Equatable {
        case idle
        case running(stage: String)
        case error(String)
    }

    struct Progress: Equatable {
        let completedDays: Int
        let totalDays: Int
        let currentDate: String?
    }

    /// `UIDocumentPickerViewController(forExporting:)` expects a file URL on
    /// disk. We wrap it with an Identifiable so SwiftUI `.sheet(item:)` can
    /// observe it.
    struct ExportArtifact: Identifiable {
        let id: UUID
        let url: URL
    }

    private let reader: HealthKitReader
    private var stopRequested = false

    init(reader: HealthKitReader = HealthKitReader()) {
        self.reader = reader
        self.lastExportAt = LastSyncStore.loadFilesExport()
    }

    func stop() { stopRequested = true }

    func exportNow() async {
        stopRequested = false
        let started = Date()
        let runID = makeRunID(date: started)
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyHealthExport-\(runID)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

            let today = DayBucketer.dayKey(start: started, timezone: TimeZone.current)
            let earliest = DayBucketer.dayKey(
                start: HKHealthStore().earliestPermittedSampleDate(),
                timezone: TimeZone.current
            )
            let days = daysInRange(from: earliest, through: today)

            let typeSequence = HealthDataTypes.allAnchoredSampleTypes
                .filter { !($0 is HKWorkoutType) }
            let deviceInfo = WorkoutFile.DeviceInfo(
                name: UIDevice.current.name,
                model: deviceModel(),
                systemVersion: UIDevice.current.systemVersion
            )

            for (idx, day) in days.enumerated() {
                if stopRequested {
                    try? FileManager.default.removeItem(at: tempRoot)
                    self.status = .idle
                    self.progress = nil
                    return
                }
                self.status = .running(stage: String(localized: "Exporting \(day.date)"))
                self.progress = Progress(
                    completedDays: idx, totalDays: days.count, currentDate: day.date
                )
                try await writeDay(
                    day: day, root: tempRoot,
                    typeSequence: typeSequence,
                    deviceInfo: deviceInfo
                )
            }

            if stopRequested {
                try? FileManager.default.removeItem(at: tempRoot)
                self.status = .idle
                self.progress = nil
                return
            }

            // Compress to a sibling .zip file. `shouldKeepParent: false` flattens
            // the export root so the archive's top level IS `apple-health/`, not
            // `MyHealthExport-<runID>/apple-health/`.
            self.status = .running(stage: String(localized: "Compressing archive"))
            self.progress = nil
            let zipURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("MyHealthExport-\(runID).zip")
            try? FileManager.default.removeItem(at: zipURL)
            try FileManager.default.zipItem(
                at: tempRoot, to: zipURL,
                shouldKeepParent: false,
                compressionMethod: .deflate
            )

            // Tree has been compressed — drop the temp dir so we don't double
            // the on-disk footprint while the user is still looking at the
            // document picker.
            try? FileManager.default.removeItem(at: tempRoot)

            let finishedAt = Date()
            self.lastExportAt = finishedAt
            LastSyncStore.stampFilesExport(finishedAt)
            self.status = .idle
            self.pendingExportURL = ExportArtifact(id: UUID(), url: zipURL)
            print("MyHealth[files]: export done run=\(runID) days=\(days.count) zip=\(zipURL.lastPathComponent)")
        } catch {
            try? FileManager.default.removeItem(at: tempRoot)
            self.status = .error(error.localizedDescription)
            self.progress = nil
            print("MyHealth[files]: export FAILED error=\(error.localizedDescription)")
        }
    }

    // MARK: - Per-day write

    private func writeDay(
        day: DayBucketer.DayKey,
        root: URL,
        typeSequence: [HKSampleType],
        deviceInfo: WorkoutFile.DeviceInfo
    ) async throws {
        // Lazily create the day directory the first time we have something to
        // write. If a day has no samples of any type, the zip simply doesn't
        // include that day.
        let dayDir = root.appendingPathComponent("apple-health/\(day.pathPrefix)", isDirectory: true)
        var didCreate = false
        func ensureDir() throws {
            if didCreate { return }
            try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
            didCreate = true
        }

        for type in typeSequence {
            if stopRequested { return }
            if let q = type as? HKQuantityType {
                let samples = try await reader.readQuantity(type: q, day: day)
                if samples.isEmpty { continue }
                let unit = samples.first?.unit ?? ""
                let envelope = DayFile.quantity(
                    date: day.date, type: q.identifier, timezone: day.timezone,
                    unit: unit, samples: samples
                )
                let body = try JSONEncoder.daySorted.encode(envelope)
                try ensureDir()
                try body.write(to: dayDir.appendingPathComponent(TypeNaming.filename(for: q.identifier)))
            } else if let c = type as? HKCategoryType {
                let samples = try await reader.readCategory(type: c, day: day)
                if samples.isEmpty { continue }
                let envelope = DayFile.category(
                    date: day.date, type: c.identifier, timezone: day.timezone,
                    samples: samples
                )
                let body = try JSONEncoder.daySorted.encode(envelope)
                try ensureDir()
                try body.write(to: dayDir.appendingPathComponent(TypeNaming.filename(for: c.identifier)))
            }
        }

        if stopRequested { return }
        let workouts = try await reader.readWorkouts(day: day)
        for w in workouts {
            if stopRequested { return }
            let route = (try? await reader.loadRoute(for: w)) ?? nil
            let wf = SampleEncoder.encode(w, events: w.workoutEvents, route: route, deviceInfo: deviceInfo)
            let body = try JSONEncoder.daySorted.encode(wf)
            try ensureDir()
            try body.write(to: dayDir.appendingPathComponent(TypeNaming.workoutFilename(uuid: wf.uuid)))
        }
    }

    // MARK: - Helpers (duplicated from SyncCoordinator — exporter is a separate pipeline)

    private func daysInRange(
        from start: DayBucketer.DayKey,
        through end: DayBucketer.DayKey
    ) -> [DayBucketer.DayKey] {
        guard start.date <= end.date else { return [] }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: end.timezone) ?? .current
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.dateFormat = "yyyy-MM-dd"
        var out: [DayBucketer.DayKey] = []
        var c = start
        let cap = 50_000
        var i = 0
        while c.date <= end.date {
            out.append(c)
            if c.date == end.date { break }
            guard let next = f.date(from: c.date).flatMap({ cal.date(byAdding: .day, value: 1, to: $0) }) else { break }
            c = DayBucketer.DayKey(date: f.string(from: next), timezone: end.timezone)
            i += 1
            if i >= cap { break }
        }
        return out
    }

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
