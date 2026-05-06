import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var sessionStore: SessionStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("backgroundSyncEnabled") private var backgroundSyncEnabled = true

    var body: some View {
        NavigationStack {
            Form {
                Section("MyLifeDB") {
                    if let session = sessionStore.myLifeDB {
                        LabeledContent("Instance", value: session.base_url)
                        LabeledContent("Path", value: session.remote_path)
                        LabeledContent("Scope", value: session.scope).font(.caption.monospaced())
                        Button("Sign out", role: .destructive) {
                            Task {
                                await ConnectAuth.signOut(session)
                                await sessionStore.refresh()
                            }
                        }
                    } else {
                        Text("Not connected").foregroundStyle(.secondary)
                    }
                }

                Section("Google Drive") {
                    if sessionStore.googleSignedIn, let user = DriveAuth.currentUser {
                        LabeledContent("Account", value: user.profile?.email ?? "")
                        Button("Sign out", role: .destructive) {
                            DriveAuth.signOut()
                            Task { await sessionStore.refresh() }
                        }
                    } else {
                        Text("Not connected").foregroundStyle(.secondary)
                    }
                }

                Section("Background sync") {
                    Toggle("Run daily in background", isOn: $backgroundSyncEnabled)
                        .onChange(of: backgroundSyncEnabled) { _, enabled in
                            if enabled {
                                BackgroundSync.scheduleNext()
                                BackgroundSync.enableBackgroundDelivery()
                            }
                            // Disabling can't actively cancel a registered task,
                            // but we stop scheduling further runs.
                        }
                }

                Section("About") {
                    LabeledContent("Version", value:
                        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"))
                    Link("Source code on GitHub", destination: URL(string: "https://github.com/")!)
                    Link("MyLifeDB Connect docs",
                         destination: URL(string: "https://my.xiaoyuanzhu.com/docs/internal/api/connect/")!)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
