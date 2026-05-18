import SwiftUI

/// MyLifeDB sync target configuration: instance URL, authorize, sign-out.
struct MyLifeDBDetailView: View {
    @EnvironmentObject var sessionStore: SessionStore
    @State private var instanceURL: String = "https://my.xiaoyuanzhu.com"
    @State private var error: String?
    @State private var working = false

    var body: some View {
        Form {
            Section("Instance") {
                if let session = sessionStore.myLifeDB {
                    LabeledContent("URL", value: session.base_url)
                    LabeledContent("Path", value: session.remote_path)
                    LabeledContent("Scope", value: session.scope)
                        .font(.caption.monospaced())
                } else {
                    TextField("Instance URL", text: $instanceURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }

            Section {
                if sessionStore.myLifeDB == nil {
                    Button {
                        Task { await authorize() }
                    } label: {
                        HStack {
                            if working { ProgressView() }
                            Text("Authorize").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(working)
                } else {
                    Button("Sign Out", role: .destructive) {
                        Task { await signOut() }
                    }
                }
            }

            if let error {
                Section {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("MyLifeDB")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func authorize() async {
        guard let url = URL(string: instanceURL) else {
            error = String(localized: "Please enter a valid URL")
            return
        }
        working = true
        defer { working = false }
        do {
            // The system browser handles consent (so iOS Universal Links can
            // route to the MyLifeDB app when installed); the callback comes
            // back via `.onOpenURL` → `ConnectAuth.shared.handleCallback`.
            _ = try await ConnectAuth.shared.signIn(baseURL: url)
            await sessionStore.refresh()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func signOut() async {
        guard let session = sessionStore.myLifeDB else { return }
        await ConnectAuth.signOut(session)
        await sessionStore.refresh()
    }
}

extension UIApplication {
    @MainActor
    var firstKeyWindow: UIWindow? {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: \.isKeyWindow)
    }
}
