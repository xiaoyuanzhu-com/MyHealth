import SwiftUI

/// App root: two-tab home, no setup wizard.
struct HomeView: View {
    var body: some View {
        TabView {
            DataTab()
                .tabItem { Label("Data", systemImage: "list.bullet.rectangle") }
            SyncTab()
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
        }
    }
}
