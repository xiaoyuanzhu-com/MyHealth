import SwiftUI
import UIKit

/// Google Drive sync target configuration: sign-in / sign-out, plus the
/// per-target Sync controls (auto-sync toggle, Sync now button, status,
/// last-run summary).
struct DriveDetailView: View {
    @EnvironmentObject var sessionStore: SessionStore
    @EnvironmentObject var coordinators: SyncCoordinators
    @State private var error: String?
    @State private var working = false

    var body: some View {
        Form {
            SyncControlsSection(
                coordinator: coordinators.googleDrive,
                autoSyncKey: "autoSyncGoogleDrive",
                isConnected: sessionStore.googleSignedIn
            )

            Section("Account") {
                if sessionStore.googleSignedIn, let user = DriveAuth.currentUser {
                    LabeledContent("Email", value: user.profile?.email ?? "—")
                    if let name = user.profile?.name {
                        LabeledContent("Name", value: name)
                    }
                } else {
                    Text("Not signed in").foregroundStyle(.secondary)
                }
            }

            Section {
                if sessionStore.googleSignedIn {
                    Button("Sign Out", role: .destructive) {
                        DriveAuth.signOut()
                        Task { await sessionStore.refresh() }
                    }
                } else {
                    Button {
                        Task { await signIn() }
                    } label: {
                        HStack {
                            if working { ProgressView() }
                            Text("Sign In with Google").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(working)
                }
            }

            Section {
                Text("Synced files are written to a folder named **MyHealth** in your Google Drive.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let error {
                Section {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Google Drive")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func signIn() async {
        working = true
        defer { working = false }
        guard let presenter = await UIApplication.shared.firstKeyWindow?.rootViewController else {
            error = String(localized: "No window to present Google sign-in.")
            return
        }
        do {
            _ = try await DriveAuth.signIn(presenting: presenter)
            await sessionStore.refresh()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
