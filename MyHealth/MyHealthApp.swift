import SwiftUI
import GoogleSignIn

@main
struct MyHealthApp: App {
    @StateObject private var coordinator = SyncCoordinator()
    @StateObject private var sessionStore = SessionStore()

    init() {
        Self.migrateLegacyOnDiskState()
        BackgroundSync.register()
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
                .environmentObject(coordinator)
                .environmentObject(sessionStore)
                .task {
                    _ = await DriveAuth.restorePreviousSignIn()
                    await sessionStore.refresh()
                    BackgroundSync.scheduleNext()
                    BackgroundSync.enableBackgroundDelivery()
                }
                .onOpenURL { url in
                    // Route OAuth callbacks back to the in-flight sign-in
                    // before falling through to GoogleSignIn's handler.
                    if ConnectAuth.shared.handleCallback(url) { return }
                    GIDSignIn.sharedInstance.handle(url)
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
