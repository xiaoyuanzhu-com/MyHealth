import SwiftUI
import HealthKit
import AuthenticationServices

struct OnboardingView: View {
    let onDone: () -> Void
    @EnvironmentObject var sessionStore: SessionStore
    @State private var step = 0
    @State private var instanceURL: String = "https://my.xiaoyuanzhu.com"
    @State private var error: String?

    var body: some View {
        TabView(selection: $step) {
            healthStep.tag(0)
            myLifeDBStep.tag(1)
            driveStep.tag(2)
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .indexViewStyle(.page(backgroundDisplayMode: .always))
    }

    // MARK: - Step 1: HealthKit

    private var healthStep: some View {
        VStack(spacing: 24) {
            Image(systemName: "heart.text.square.fill")
                .resizable().scaledToFit().frame(width: 96, height: 96)
                .foregroundStyle(.pink)
            Text("Read Apple Health").font(.largeTitle.bold())
            Text("MyHealth needs read access to your Health data so it can sync it to the destinations you choose.")
                .multilineTextAlignment(.center).padding(.horizontal)
            Spacer()
            Button {
                Task {
                    do {
                        try await HealthKitAuth().requestAuthorization()
                        step = 1
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
            } label: {
                Text("Grant access").font(.headline).frame(maxWidth: .infinity).padding()
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)

            if let error { Text(error).foregroundStyle(.red).font(.caption) }
        }
        .padding(.top, 80)
    }

    // MARK: - Step 2: MyLifeDB

    private var myLifeDBStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "externaldrive.fill.badge.icloud")
                .resizable().scaledToFit().frame(width: 96, height: 96)
                .foregroundStyle(.blue)
            Text("Connect MyLifeDB").font(.largeTitle.bold())
            Text("Enter your MyLifeDB instance URL. You'll authorize MyHealth in your browser.")
                .multilineTextAlignment(.center).padding(.horizontal)

            TextField("Instance URL", text: $instanceURL)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal)

            if sessionStore.myLifeDB != nil {
                Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }

            Spacer()
            HStack(spacing: 12) {
                Button("Skip") { step = 2 }
                    .buttonStyle(.bordered)
                Button {
                    Task { await connectMyLifeDB() }
                } label: {
                    Text(sessionStore.myLifeDB == nil ? "Authorize" : "Continue").bold()
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)

            if let error { Text(error).foregroundStyle(.red).font(.caption).padding(.horizontal) }
        }
        .padding(.top, 80)
    }

    private func connectMyLifeDB() async {
        if sessionStore.myLifeDB != nil { step = 2; return }
        guard let url = URL(string: instanceURL) else {
            self.error = "Please enter a valid URL"
            return
        }
        let anchor = await ASPresentationAnchor.firstWindow ?? ASPresentationAnchor()
        do {
            _ = try await ConnectAuth().signIn(baseURL: url, anchor: anchor)
            await sessionStore.refresh()
            self.error = nil
            step = 2
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Step 3: Google Drive

    private var driveStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "icloud.and.arrow.up.fill")
                .resizable().scaledToFit().frame(width: 96, height: 96)
                .foregroundStyle(.green)
            Text("Connect Google Drive").font(.largeTitle.bold())
            Text("Optional — sync the same files to a folder named MyHealth on your Drive.")
                .multilineTextAlignment(.center).padding(.horizontal)

            if sessionStore.googleSignedIn {
                Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }

            Spacer()
            HStack(spacing: 12) {
                Button("Skip") { onDone() }.buttonStyle(.bordered)
                Button {
                    Task { await connectDrive() }
                } label: {
                    Text(sessionStore.googleSignedIn ? "Done" : "Sign in").bold()
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                }.buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)

            if let error { Text(error).foregroundStyle(.red).font(.caption).padding(.horizontal) }
        }
        .padding(.top, 80)
    }

    private func connectDrive() async {
        if sessionStore.googleSignedIn { onDone(); return }
        guard let presenter = await UIApplication.shared.firstKeyWindow?.rootViewController else {
            self.error = "No window to present Google sign-in."
            return
        }
        do {
            _ = try await DriveAuth.signIn(presenting: presenter)
            await sessionStore.refresh()
            self.error = nil
            onDone()
        } catch {
            self.error = error.localizedDescription
        }
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

extension ASPresentationAnchor {
    @MainActor
    static var firstWindow: ASPresentationAnchor? {
        UIApplication.shared.firstKeyWindow
    }
}
