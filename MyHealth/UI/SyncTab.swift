import SwiftUI

/// Sync tab: trigger button + status, sync targets list, background-sync
/// toggle, and About section.
struct SyncTab: View {
    @EnvironmentObject var coordinator: SyncCoordinator
    @EnvironmentObject var sessionStore: SessionStore
    @AppStorage("backgroundSyncEnabled") private var backgroundSyncEnabled = true

    var body: some View {
        NavigationStack {
            List {
                Section {
                    SyncNowButton()
                    LastBatchSummary()
                }

                Section("Sync Targets") {
                    NavigationLink {
                        MyLifeDBDetailView()
                    } label: {
                        SyncTargetRow(
                            title: "MyLifeDB",
                            subtitle: sessionStore.myLifeDB?.base_url ?? String(localized: "Not connected"),
                            icon: "externaldrive.fill.badge.icloud",
                            connected: sessionStore.myLifeDB != nil
                        )
                    }
                    NavigationLink {
                        WebDAVDetailView()
                    } label: {
                        SyncTargetRow(
                            title: "WebDAV",
                            subtitle: sessionStore.webdav?.displayHost ?? String(localized: "Not connected"),
                            icon: "server.rack",
                            connected: sessionStore.webdav != nil
                        )
                    }
                    NavigationLink {
                        DriveDetailView()
                    } label: {
                        SyncTargetRow(
                            title: "Google Drive",
                            subtitle: sessionStore.googleSignedIn
                                ? String(localized: "Signed in")
                                : String(localized: "Not connected"),
                            icon: "icloud.and.arrow.up.fill",
                            connected: sessionStore.googleSignedIn
                        )
                    }
                    NavigationLink {
                        ComingSoonDetailView(title: "iCloud")
                    } label: {
                        SyncTargetRow(
                            title: "iCloud",
                            subtitle: String(localized: "Coming soon"),
                            icon: "icloud.fill",
                            connected: false
                        )
                    }
                    NavigationLink {
                        ComingSoonDetailView(title: "OneDrive")
                    } label: {
                        SyncTargetRow(
                            title: "OneDrive",
                            subtitle: String(localized: "Coming soon"),
                            icon: "cloud.fill",
                            connected: false
                        )
                    }
                }

                Section("Background Sync") {
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
            .listStyle(.insetGrouped)
        }
    }
}

private struct SyncNowButton: View {
    @EnvironmentObject var coordinator: SyncCoordinator
    @EnvironmentObject var sessionStore: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                Task { await action() }
            } label: {
                HStack {
                    Image(systemName: icon)
                    Text(title).bold()
                }
                .frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(disabled)

            statusLine
        }
    }

    private var enabledDestinations: Set<SyncCoordinator.Destination> {
        var s: Set<SyncCoordinator.Destination> = []
        if sessionStore.myLifeDB != nil { s.insert(.myLifeDB) }
        if sessionStore.googleSignedIn { s.insert(.googleDrive) }
        if sessionStore.webdav != nil { s.insert(.webdav) }
        return s
    }

    private var icon: String {
        switch coordinator.status {
        case .running: return "stop.fill"
        default: return "arrow.triangle.2.circlepath"
        }
    }

    private var title: String {
        switch coordinator.status {
        case .running: return String(localized: "Stop")
        default: return String(localized: "Sync now")
        }
    }

    private var disabled: Bool {
        if enabledDestinations.isEmpty && !coordinator.hasPendingRun { return true }
        return false
    }

    private func action() async {
        switch coordinator.status {
        case .running:
            coordinator.stop()
        case .idle, .error:
            await coordinator.runOnce(enabledDestinations: enabledDestinations)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch coordinator.status {
        case .running(let stage):
            if let p = coordinator.progress {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        if let date = p.currentDate, let typeName = p.currentTypeName {
                            Text("\(date) · \(typeName) (\(p.currentTypeIndex + 1)/\(p.totalTypes))")
                                .font(.caption2).foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Spacer()
                        Text("Day \(p.completedDays + 1) of \(p.totalDays)")
                            .font(.caption2).foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    ProgressView(value: Double(p.completedDays), total: Double(max(1, p.totalDays)))
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(stage).foregroundStyle(.secondary).font(.caption)
                }
            }
        case .error(let msg):
            Text(msg).foregroundStyle(.red).font(.caption)
        case .idle:
            if let pending = coordinator.pendingRunSummary {
                Text("Stopped at day \(pending.completedDays) of \(pending.totalDays). Tap Sync now to continue.")
                    .foregroundStyle(.secondary).font(.caption)
            } else {
                EmptyView()
            }
        }
    }
}

private struct LastBatchSummary: View {
    @EnvironmentObject var coordinator: SyncCoordinator

    var body: some View {
        if let r = coordinator.lastResult {
            VStack(alignment: .leading, spacing: 6) {
                Text("Last sync").font(.caption).foregroundStyle(.secondary)
                Text(r.runID).font(.caption.monospaced())
                HStack {
                    Text("Days"); Spacer()
                    Text("\(r.totalDays)").monospacedDigit()
                }
                HStack {
                    Text("Samples"); Spacer()
                    Text("\(r.totalSamples)").monospacedDigit()
                }
                HStack {
                    Text("Workouts"); Spacer()
                    Text("\(r.totalWorkouts)").monospacedDigit()
                }
                .font(.subheadline)
                HStack(spacing: 12) {
                    if r.myLifeDBUploaded {
                        Label("MyLifeDB", systemImage: "checkmark")
                            .labelStyle(.titleAndIcon).font(.caption)
                    }
                    if r.driveUploaded {
                        Label("Drive", systemImage: "checkmark")
                            .labelStyle(.titleAndIcon).font(.caption)
                    }
                    if r.webdavUploaded {
                        Label("WebDAV", systemImage: "checkmark")
                            .labelStyle(.titleAndIcon).font(.caption)
                    }
                }
                .foregroundStyle(.green)
            }
            .padding(.vertical, 2)
        }
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

private struct SyncTargetRow: View {
    let title: String
    let subtitle: String
    let icon: String
    let connected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill(connected ? Color.green : Color.secondary.opacity(0.3))
                .frame(width: 8, height: 8)
                .accessibilityLabel(connected ? "Connected" : "Not connected")
        }
    }
}
