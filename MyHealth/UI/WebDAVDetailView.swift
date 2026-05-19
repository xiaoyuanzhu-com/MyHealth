import SwiftUI

/// WebDAV sync target configuration: server URL, credentials, folder, and a
/// connectivity check before saving.
struct WebDAVDetailView: View {
    @EnvironmentObject var sessionStore: SessionStore

    @State private var baseURL: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var rootFolder: String = "MyHealth"

    @State private var error: String?
    @State private var working = false

    var body: some View {
        Form {
            Section("Server") {
                if let creds = sessionStore.webdav {
                    LabeledContent("URL", value: creds.base_url)
                    LabeledContent("User", value: creds.username)
                    LabeledContent("Folder", value: creds.root_folder)
                } else {
                    TextField("Server URL", text: $baseURL,
                              prompt: Text(verbatim: "https://example.com/remote.php/dav/files/me"))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password or app password", text: $password)
                    TextField("Folder", text: $rootFolder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }

            Section {
                if sessionStore.webdav != nil {
                    Button("Sign Out", role: .destructive) {
                        WebDAVStore.clear()
                        Task { await sessionStore.refresh() }
                    }
                } else {
                    Button {
                        Task { await signIn() }
                    } label: {
                        HStack {
                            if working { ProgressView() }
                            Text("Connect").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(working || !canSubmit)
                }
            }

            Section {
                Text("The password is stored in the iOS Keychain on this device.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let error {
                Section {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("WebDAV")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var canSubmit: Bool {
        guard let url = URL(string: baseURL), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return false }
        return !username.isEmpty && !password.isEmpty && !rootFolder.isEmpty
    }

    private func signIn() async {
        working = true
        defer { working = false }
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip trailing slashes so PUT URLs build cleanly.
        let normalizedURL = trimmedURL.hasSuffix("/")
            ? String(trimmedURL.dropLast()) : trimmedURL
        let creds = WebDAVCredentials(
            base_url: normalizedURL,
            username: username,
            password: password,
            root_folder: rootFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        do {
            try await WebDAVClient(credentials: creds).verifyAccess()
            try WebDAVStore.save(creds)
            await sessionStore.refresh()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
