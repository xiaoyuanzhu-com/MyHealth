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
                            subtitle: sessionStore.myLifeDB?.base_url ?? "Not connected",
                            icon: "externaldrive.fill.badge.icloud",
                            connected: sessionStore.myLifeDB != nil
                        )
                    }
                    NavigationLink {
                        DriveDetailView()
                    } label: {
                        SyncTargetRow(
                            title: "Google Drive",
                            subtitle: sessionStore.googleSignedIn ? "Signed in" : "Not connected",
                            icon: "icloud.and.arrow.up.fill",
                            connected: sessionStore.googleSignedIn
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
            .navigationTitle("Sync")
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

            if showsAbort {
                Button(role: .destructive) {
                    coordinator.abort()
                } label: {
                    Text("Abort and discard progress")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            statusLine
        }
    }

    private var enabledDestinations: Set<SyncCoordinator.Destination> {
        var s: Set<SyncCoordinator.Destination> = []
        if sessionStore.myLifeDB != nil { s.insert(.myLifeDB) }
        if sessionStore.googleSignedIn { s.insert(.googleDrive) }
        return s
    }

    private var icon: String {
        switch coordinator.status {
        case .running: return "pause.fill"
        case .paused: return "play.fill"
        case .error: return "arrow.triangle.2.circlepath"
        case .idle: return "arrow.triangle.2.circlepath"
        }
    }

    private var title: String {
        switch coordinator.status {
        case .running: return "Pause"
        case .paused(let done, let total): return "Resume (\(done)/\(total))"
        case .error: return "Retry sync"
        case .idle: return coordinator.hasPendingRun ? "Resume sync" : "Sync now"
        }
    }

    private var disabled: Bool {
        if enabledDestinations.isEmpty && !coordinator.hasPendingRun { return true }
        return false
    }

    private var showsAbort: Bool {
        switch coordinator.status {
        case .paused: return true
        case .running: return true
        case .idle: return coordinator.hasPendingRun
        case .error: return coordinator.hasPendingRun
        }
    }

    private func action() async {
        switch coordinator.status {
        case .running:
            coordinator.pause()
        case .paused, .idle, .error:
            await coordinator.runOnce(enabledDestinations: enabledDestinations)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch coordinator.status {
        case .running(let stage):
            HStack(spacing: 8) {
                ProgressView()
                Text(stage).foregroundStyle(.secondary).font(.caption)
            }
            if let p = coordinator.progress {
                ProgressView(value: Double(p.completedDays), total: Double(max(1, p.totalDays)))
            }
        case .paused(let done, let total):
            Text("Paused at day \(done) of \(total).").foregroundStyle(.secondary).font(.caption)
        case .error(let msg):
            Text(msg).foregroundStyle(.red).font(.caption)
        case .idle:
            EmptyView()
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
                }
                .foregroundStyle(.green)
            }
            .padding(.vertical, 2)
        }
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
