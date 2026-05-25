import SwiftUI
import UIKit

/// Sync tab: list of sync targets, plus settings and About sections. The
/// per-target Auto-sync toggle and Sync now button were absorbed into each
/// target's detail page in the per-target sync refactor — this view is
/// purely navigation now.
struct SyncTab: View {
    @EnvironmentObject var sessionStore: SessionStore
    @EnvironmentObject var coordinators: SyncCoordinators
    @AppStorage("appLanguage") private var appLanguage = "system"
    @State private var manageAccessShown = false

    var body: some View {
        NavigationStack {
            List {
                Section("Sync Targets") {
                    NavigationLink {
                        MyLifeDBDetailView()
                    } label: {
                        RemoteTargetRow(
                            coordinator: coordinators.myLifeDB,
                            title: "MyLifeDB",
                            subtitle: sessionStore.myLifeDB?.base_url ?? String(localized: "Not connected"),
                            icon: .asset("my-life-db"),
                            connected: sessionStore.myLifeDB != nil
                        )
                    }
                    NavigationLink {
                        WebDAVDetailView()
                    } label: {
                        RemoteTargetRow(
                            coordinator: coordinators.webdav,
                            title: "WebDAV",
                            subtitle: sessionStore.webdav?.displayHost ?? String(localized: "Not connected"),
                            icon: .system("server.rack"),
                            connected: sessionStore.webdav != nil
                        )
                    }
                    NavigationLink {
                        DriveDetailView()
                    } label: {
                        RemoteTargetRow(
                            coordinator: coordinators.googleDrive,
                            title: "Google Drive",
                            subtitle: sessionStore.googleSignedIn
                                ? String(localized: "Signed in")
                                : String(localized: "Not connected"),
                            icon: .asset("google-drive"),
                            connected: sessionStore.googleSignedIn
                        )
                    }
                    NavigationLink {
                        FilesDetailView()
                    } label: {
                        FilesTargetRow(exporter: coordinators.files)
                    }
                    NavigationLink {
                        ComingSoonDetailView(title: "iCloud")
                    } label: {
                        SyncTargetRow(
                            title: "iCloud",
                            subtitle: String(localized: "Coming soon"),
                            icon: .asset("icloud"),
                            connected: false,
                            isBusy: false
                        )
                    }
                    NavigationLink {
                        ComingSoonDetailView(title: "OneDrive")
                    } label: {
                        SyncTargetRow(
                            title: "OneDrive",
                            subtitle: String(localized: "Coming soon"),
                            icon: .asset("onedrive"),
                            connected: false,
                            isBusy: false
                        )
                    }
                }

                Section("Settings") {
                    Picker("Language", selection: $appLanguage) {
                        Text("System").tag("system")
                        Text("English").tag("en")
                        Text("中文").tag("zh-Hans")
                    }
                    Button {
                        manageAccessShown = true
                    } label: {
                        HStack {
                            Text("Manage Access").foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
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
            .listStyle(.insetGrouped)
            .sheet(isPresented: $manageAccessShown) {
                ManageAccessSheet()
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
        }
    }
}

/// Half-height instructional sheet. iOS does not expose a public URL scheme
/// to deep-link onto MyHealth's HealthKit page, so we walk the user through
/// the navigation manually and hand off to the Health app's root.
private struct ManageAccessSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let steps: [LocalizedStringKey] = [
        "Open the Health app",
        "Tap your profile picture (top-right)",
        "Choose “Apps and Services”",
        "Find “MyHealth” in the list",
        "Toggle the categories you want to share"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Manage HealthKit Access")
                .font(.title3.bold())
                .padding(.top, 24)
                .padding(.horizontal, 24)

            Text("iOS doesn’t let apps jump straight to their permission page. Follow these steps in the Health app:")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
                .padding(.horizontal, 24)

            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(steps.enumerated()), id: \.offset) { idx, step in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(idx + 1).")
                            .font(.body.monospacedDigit().bold())
                            .foregroundStyle(.tint)
                            .frame(width: 20, alignment: .trailing)
                        Text(step).font(.body)
                    }
                }
            }
            .padding(.top, 20)
            .padding(.horizontal, 24)

            Spacer(minLength: 0)

            Button {
                openHealthApp()
                dismiss()
            } label: {
                Text("Open Health App")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
    }

    private func openHealthApp() {
        guard let url = URL(string: "x-apple-health://") else { return }
        UIApplication.shared.open(url)
    }
}

struct ComingSoonDetailView: View {
    let title: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "hammer.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Coming soon")
                .font(.title3.weight(.semibold))
            Text("\(title) sync isn't available yet.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Wraps a `SyncCoordinator` so the row re-renders when its status changes
/// (running → spinner badge, idle → connection dot).
private struct RemoteTargetRow: View {
    @ObservedObject var coordinator: SyncCoordinator
    let title: String
    let subtitle: String
    let icon: SyncTargetRow.Icon
    let connected: Bool

    var body: some View {
        SyncTargetRow(
            title: title, subtitle: subtitle, icon: icon,
            connected: connected,
            isBusy: isBusy
        )
    }

    private var isBusy: Bool {
        if case .running = coordinator.status { return true }
        return false
    }
}

/// Files-target row variant — the exporter doesn't have "connected" state,
/// just busy/idle.
private struct FilesTargetRow: View {
    @ObservedObject var exporter: FilesExporter

    var body: some View {
        SyncTargetRow(
            title: String(localized: "Files"),
            subtitle: subtitle,
            icon: .system("folder"),
            connected: true,
            isBusy: isBusy
        )
    }

    private var subtitle: String {
        switch exporter.status {
        case .running: return String(localized: "Exporting…")
        case .error: return String(localized: "Export failed")
        case .idle:
            if let last = exporter.lastExportAt {
                let f = RelativeDateTimeFormatter()
                f.unitsStyle = .short
                return String(localized: "Last export \(f.localizedString(for: last, relativeTo: Date()))")
            }
            return String(localized: "Export to a zip file")
        }
    }

    private var isBusy: Bool {
        if case .running = exporter.status { return true }
        return false
    }
}

struct SyncTargetRow: View {
    enum Icon {
        case system(String)
        case asset(String)
    }

    let title: String
    let subtitle: String
    let icon: Icon
    let connected: Bool
    let isBusy: Bool

    var body: some View {
        HStack(spacing: 12) {
            iconView
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Syncing")
            } else {
                Circle()
                    .fill(connected ? Color.green : Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
                    .accessibilityLabel(connected ? "Connected" : "Not connected")
            }
        }
    }

    @ViewBuilder
    private var iconView: some View {
        switch icon {
        case .system(let name):
            Image(systemName: name).font(.title3).foregroundStyle(.tint)
        case .asset(let name):
            Image(name).resizable().scaledToFit()
        }
    }
}
