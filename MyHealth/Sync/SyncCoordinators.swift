import Foundation
import SwiftUI

/// Holds the per-destination sync coordinators and the Files exporter, plus
/// one-time migration of the old global on-disk sync state into the new
/// per-destination buckets.
///
/// Each detail page (`MyLifeDBDetailView`, `DriveDetailView`, etc.) reads its
/// own coordinator from here; the SyncTab list reads all of them for per-row
/// status badges. The instance lives on `MyHealthApp` as a `@StateObject` and
/// is injected via `.environmentObject`.
@MainActor
final class SyncCoordinators: ObservableObject {
    let myLifeDB: SyncCoordinator
    let googleDrive: SyncCoordinator
    let webdav: SyncCoordinator
    let files: FilesExporter

    init() {
        // Note: callers must call `SyncCoordinators.migrateGlobalStateIfNeeded()`
        // from `MyHealthApp.init` BEFORE constructing this object, so the
        // background-launch path (which never instantiates a `SyncCoordinators`
        // env object) also benefits from the migration.
        self.myLifeDB = SyncCoordinator(destination: .myLifeDB)
        self.googleDrive = SyncCoordinator(destination: .googleDrive)
        self.webdav = SyncCoordinator(destination: .webdav)
        self.files = FilesExporter()
    }

    /// Returns the coordinator for the given destination.
    func coordinator(for destination: Destination) -> SyncCoordinator {
        switch destination {
        case .myLifeDB:    return myLifeDB
        case .googleDrive: return googleDrive
        case .webdav:      return webdav
        }
    }

    /// Pause every coordinator currently running. Called when the app moves
    /// to the background — `SyncCoordinator.pauseForBackgrounding` is a
    /// no-op if that coordinator is idle.
    func pauseAllForBackgrounding() {
        myLifeDB.pauseForBackgrounding()
        googleDrive.pauseForBackgrounding()
        webdav.pauseForBackgrounding()
    }

    // MARK: - Migration

    private static let migrationFlagKey = "migratedToPerDestinationSync.v1"

    /// One-shot migration of the old global sync state files into the new
    /// per-destination layout. Idempotent — protected by a `UserDefaults`
    /// flag so it only runs once.
    ///
    /// We conservatively copy the old anchor/hashes into ALL three destination
    /// buckets. Rationale: prior to this refactor every successful run wrote
    /// to all enabled targets in lockstep, so the global anchor reflects
    /// "every target that was connected at the time was synced through here."
    /// Worst case the first per-target run after upgrade triggers a small
    /// walk-back, which is cheap.
    ///
    /// We also fan the legacy `backgroundSyncEnabled` flag out into the three
    /// per-target keys, preserving the user's choice if they had explicitly
    /// disabled BG sync.
    static func migrateGlobalStateIfNeeded() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: migrationFlagKey) { return }
        defer { defaults.set(true, forKey: migrationFlagKey) }

        let fm = FileManager.default
        guard let dir = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return }

        let oldCursor = dir.appendingPathComponent("sync-cursor.json")
        let oldHashes = dir.appendingPathComponent("day-hashes.json")
        let oldRunState = dir.appendingPathComponent("sync-run-state.json")

        let cursorData = try? Data(contentsOf: oldCursor)
        let hashesData = try? Data(contentsOf: oldHashes)
        let runStateData = try? Data(contentsOf: oldRunState)

        for destination in Destination.allCases {
            if let data = cursorData {
                try? data.write(to: SyncCursor.url(for: destination), options: .atomic)
            }
            if let data = hashesData {
                try? data.write(to: DayHashStore.url(for: destination), options: .atomic)
            }
            // The old run-state shape matches the new one (the per-destination
            // change is only the filename), so copying preserves a pending
            // run. Whichever target the user resumes will pick up where the
            // global run left off; the other two start fresh on their first
            // run, which is fine — they'll walk back over the same days.
            if let data = runStateData {
                try? data.write(to: SyncRunStore.url(for: destination), options: .atomic)
            }
        }

        try? fm.removeItem(at: oldCursor)
        try? fm.removeItem(at: oldHashes)
        try? fm.removeItem(at: oldRunState)

        // Fan the legacy BG-sync toggle out to per-target flags. If the user
        // explicitly disabled it, all three new toggles start off; otherwise
        // (key absent or true) all three start on, matching previous default.
        let legacyEnabled = defaults.object(forKey: "backgroundSyncEnabled") as? Bool ?? true
        defaults.set(legacyEnabled, forKey: "autoSyncMyLifeDB")
        defaults.set(legacyEnabled, forKey: "autoSyncGoogleDrive")
        defaults.set(legacyEnabled, forKey: "autoSyncWebDAV")
        defaults.removeObject(forKey: "backgroundSyncEnabled")

        print("MyHealth: migrated global sync state to per-destination layout (legacyEnabled=\(legacyEnabled))")
    }
}
