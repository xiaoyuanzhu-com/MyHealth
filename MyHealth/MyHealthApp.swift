import SwiftUI
import GoogleSignIn

@main
struct MyHealthApp: App {
    @StateObject private var coordinator = SyncCoordinator()
    @StateObject private var sessionStore = SessionStore()

    init() {
        BackgroundSync.register()
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

    func refresh() async {
        myLifeDB = (try? TokenStore.load()) ?? nil
        googleSignedIn = DriveAuth.currentUser != nil
    }
}
