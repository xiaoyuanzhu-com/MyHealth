import SwiftUI
import GoogleSignIn

@main
struct MyHealthApp: App {
    @StateObject private var coordinators = SyncCoordinators()
    @StateObject private var sessionStore = SessionStore()
    @AppStorage("appLanguage") private var appLanguage = "system"
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Self.migrateLegacyOnDiskState()
        // Migrate the old global sync-state files into per-destination buckets
        // BEFORE background tasks register, so a BG launch (which never
        // instantiates the SyncCoordinators env object) still sees the
        // migrated state on its first coordinator read.
        SyncCoordinators.migrateGlobalStateIfNeeded()
        BackgroundSync.register()
        // Observer queries don't survive process termination, so re-register
        // on every launch — including BGTask launches that never reach the
        // scene's .task below.
        BackgroundSync.enableBackgroundDelivery()
    }

    private var selectedLocale: Locale {
        switch appLanguage {
        case "en": return Locale(identifier: "en")
        case "zh-Hans": return Locale(identifier: "zh-Hans")
        default: return .autoupdatingCurrent
        }
    }

    /// Persist the choice into `AppleLanguages` so `String(localized:)` —
    /// which reads from `Bundle.main.preferredLocalizations`, not the SwiftUI
    /// environment — picks up the new language on the next view render.
    private func applyAppleLanguages() {
        let key = "AppleLanguages"
        switch appLanguage {
        case "en":
            UserDefaults.standard.set(["en"], forKey: key)
        case "zh-Hans":
            UserDefaults.standard.set(["zh-Hans"], forKey: key)
        default:
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// One-time cleanup of artefacts from the pre-day-by-day-sync layout:
    /// `anchors.json` is no longer read; an old-shape `sync-run-state.json`
    /// can't be decoded under the new model, so deleting it makes
    /// `SyncRunStore.load` correctly report "no pending run" instead of nil-
    /// from-decode-failure. Idempotent and cheap — runs every launch.
    private static func migrateLegacyOnDiskState() {
        guard let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        ) else { return }

        let anchors = appSupport.appendingPathComponent("anchors.json")
        try? FileManager.default.removeItem(at: anchors)

        let stateURL = appSupport.appendingPathComponent("sync-run-state.json")
        if let data = try? Data(contentsOf: stateURL),
           (try? JSONDecoder().decode(SyncRunState.self, from: data)) == nil {
            try? FileManager.default.removeItem(at: stateURL)
        }
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(coordinators)
                .environmentObject(sessionStore)
                .environment(\.locale, selectedLocale)
                .task {
                    applyAppleLanguages()
                    _ = await DriveAuth.restorePreviousSignIn()
                    await sessionStore.refresh()
                    BackgroundSync.scheduleNext()
                }
                .onChange(of: appLanguage) { _, _ in
                    applyAppleLanguages()
                }
                .onOpenURL { url in
                    // Route OAuth callbacks back to the in-flight sign-in
                    // before falling through to GoogleSignIn's handler.
                    if ConnectAuth.shared.handleCallback(url) { return }
                    GIDSignIn.sharedInstance.handle(url)
                }
                .onChange(of: scenePhase) { _, newPhase in
                    // iOS suspends a backgrounded app within ~5s; let each
                    // coordinator checkpoint and exit cleanly before the
                    // in-flight URLSessions get cancelled and HealthKit
                    // becomes inaccessible on device lock.
                    if newPhase == .background {
                        coordinators.pauseAllForBackgrounding()
                    }
                }
        }
    }
}

/// Reactive snapshot of the user's auth state across destinations.
@MainActor
final class SessionStore: ObservableObject {
    @Published var myLifeDB: MyLifeDBSession?
    @Published var googleSignedIn: Bool = false
    @Published var webdav: WebDAVCredentials?

    func refresh() async {
        myLifeDB = (try? TokenStore.load()) ?? nil
        googleSignedIn = DriveAuth.currentUser != nil
        webdav = WebDAVStore.load()
    }
}
