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
        Button {
            Task { await coordinator.runOnce(enabledDestinations: enabledDestinations) }
        } label: {
            HStack {
                if case .running = coordinator.status {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                Text(title).bold()
            }
            .frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .disabled(disabled)

        if case .error(let msg) = coordinator.status {
            Text(msg).foregroundStyle(.red).font(.caption)
        } else if case .running(let stage) = coordinator.status {
            Text(stage).foregroundStyle(.secondary).font(.caption)
        }
    }

    private var enabledDestinations: Set<SyncCoordinator.Destination> {
        var s: Set<SyncCoordinator.Destination> = []
        if sessionStore.myLifeDB != nil { s.insert(.myLifeDB) }
        if sessionStore.googleSignedIn { s.insert(.googleDrive) }
        return s
    }

    private var title: String {
        switch coordinator.status {
        case .running: return "Syncing…"
        case .error: return "Retry sync"
        case .idle: return "Sync now"
        }
    }

    private var disabled: Bool {
        if enabledDestinations.isEmpty { return true }
        if case .running = coordinator.status { return true }
        return false
    }
}

private struct LastBatchSummary: View {
    @EnvironmentObject var coordinator: SyncCoordinator

    var body: some View {
        if let result = coordinator.lastResult {
            VStack(alignment: .leading, spacing: 6) {
                Text("Last batch").font(.caption).foregroundStyle(.secondary)
                Text(result.batchID).font(.caption.monospaced())
                ForEach(result.counts.sorted(by: { $0.key < $1.key }), id: \.key) { item in
                    HStack {
                        Text(item.key.replacingOccurrences(of: "_", with: " ").capitalized)
                        Spacer()
                        Text("\(item.value)").monospacedDigit()
                    }
                    .font(.subheadline)
                }
                HStack(spacing: 12) {
                    if result.myLifeDBUploaded {
                        Label("MyLifeDB", systemImage: "checkmark")
                            .labelStyle(.titleAndIcon).font(.caption)
                    }
                    if result.driveUploaded {
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
