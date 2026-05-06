import SwiftUI

struct ContentView: View {
    @EnvironmentObject var coordinator: SyncCoordinator
    @EnvironmentObject var sessionStore: SessionStore
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    SyncStatusView()
                    destinationsSection
                    actionsSection
                    recentBatchSection
                }
                .padding()
            }
            .navigationTitle("MyHealth")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
        }
    }

    private var destinationsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Destinations").font(.headline)
            DestinationRow(
                title: "MyLifeDB",
                subtitle: sessionStore.myLifeDB?.base_url ?? "Not connected",
                connected: sessionStore.myLifeDB != nil,
                systemImage: "externaldrive.fill.badge.icloud"
            )
            DestinationRow(
                title: "Google Drive",
                subtitle: sessionStore.googleSignedIn ? "Signed in" : "Not connected",
                connected: sessionStore.googleSignedIn,
                systemImage: "icloud.and.arrow.up.fill"
            )
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var actionsSection: some View {
        VStack(spacing: 12) {
            Button {
                Task { await coordinator.runOnce(enabledDestinations: enabledDestinations) }
            } label: {
                HStack {
                    if case .running = coordinator.status {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    Text(syncButtonTitle).bold()
                }
                .frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(syncDisabled)

            if case .error(let msg) = coordinator.status {
                Text(msg).foregroundStyle(.red).font(.caption).multilineTextAlignment(.leading)
            }
        }
    }

    private var recentBatchSection: some View {
        Group {
            if let result = coordinator.lastResult {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Last sync").font(.headline)
                    Text(result.batchID).font(.caption).foregroundStyle(.secondary)
                    ForEach(result.counts.sorted(by: { $0.key < $1.key }), id: \.key) { item in
                        HStack {
                            Text(item.key.replacingOccurrences(of: "_", with: " ").capitalized)
                            Spacer()
                            Text("\(item.value)").monospacedDigit()
                        }
                        .font(.subheadline)
                    }
                    HStack(spacing: 8) {
                        if result.myLifeDBUploaded {
                            Label("MyLifeDB", systemImage: "checkmark").labelStyle(.titleAndIcon).font(.caption)
                        }
                        if result.driveUploaded {
                            Label("Drive", systemImage: "checkmark").labelStyle(.titleAndIcon).font(.caption)
                        }
                    }
                    .foregroundStyle(.green)
                }
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var enabledDestinations: Set<SyncCoordinator.Destination> {
        var s: Set<SyncCoordinator.Destination> = []
        if sessionStore.myLifeDB != nil { s.insert(.myLifeDB) }
        if sessionStore.googleSignedIn { s.insert(.googleDrive) }
        return s
    }

    private var syncButtonTitle: String {
        switch coordinator.status {
        case .running(let stage): return stage
        case .error: return "Retry sync"
        case .idle: return "Sync now"
        }
    }

    private var syncDisabled: Bool {
        if enabledDestinations.isEmpty { return true }
        if case .running = coordinator.status { return true }
        return false
    }
}

struct DestinationRow: View {
    let title: String
    let subtitle: String
    let connected: Bool
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage).font(.title2).frame(width: 32)
            VStack(alignment: .leading) {
                Text(title).font(.body)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: connected ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(connected ? .green : .secondary)
        }
    }
}
