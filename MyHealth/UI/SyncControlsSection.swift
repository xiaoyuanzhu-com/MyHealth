import SwiftUI

/// Shared "Sync" section for the three remote-target detail pages
/// (MyLifeDB, Drive, WebDAV). Encapsulates:
///   * the "Auto-sync daily" toggle, persisted via the destination-keyed
///     `@AppStorage` key the caller supplies,
///   * the "Sync now" / "Stop" button + its disabled state,
///   * the running-stage status line, progress bar, error message,
///   * the post-completion summary (sample / workout / day counts),
///   * the "Last synced N ago" line.
///
/// The Files target's detail page does NOT use this — it has its own
/// one-shot Export controls — but everything else shares this view.
struct SyncControlsSection: View {
    @ObservedObject var coordinator: SyncCoordinator
    let autoSyncKey: String
    /// True when the destination has credentials. The Sync now button is
    /// disabled (and shown as "Connect first") when false; the toggle stays
    /// active either way so the user can pre-configure it.
    let isConnected: Bool

    @AppStorage private var autoSyncEnabled: Bool

    init(coordinator: SyncCoordinator, autoSyncKey: String, isConnected: Bool) {
        self.coordinator = coordinator
        self.autoSyncKey = autoSyncKey
        self.isConnected = isConnected
        self._autoSyncEnabled = AppStorage(wrappedValue: true, autoSyncKey)
    }

    var body: some View {
        Section("Sync") {
            Toggle("Auto-sync daily", isOn: $autoSyncEnabled)
                .onChange(of: autoSyncEnabled) { _, enabled in
                    if enabled {
                        BackgroundSync.scheduleNext()
                        BackgroundSync.enableBackgroundDelivery()
                    }
                }

            SyncActionButton(coordinator: coordinator, isConnected: isConnected)

            SyncStatusLine(coordinator: coordinator)
        }
    }
}

/// The "Sync now" / "Stop" button. Toggles label and behavior based on
/// `coordinator.status`; disabled when the destination has no credentials
/// and no run is pending to be resumed.
private struct SyncActionButton: View {
    @ObservedObject var coordinator: SyncCoordinator
    let isConnected: Bool

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            HStack {
                Image(systemName: icon)
                Text(title).bold()
            }
            .frame(maxWidth: .infinity).padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .disabled(disabled)
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
        if case .running = coordinator.status { return false }  // always allow Stop
        if !isConnected && !coordinator.hasPendingRun { return true }
        return false
    }

    private func action() async {
        switch coordinator.status {
        case .running:
            coordinator.stop()
        case .idle, .error:
            await coordinator.runOnce()
        }
    }
}

/// Combined "what is the coordinator doing right now" line: running
/// progress, error message, idle hint about pending runs, or
/// last-completed summary.
struct SyncStatusLine: View {
    @ObservedObject var coordinator: SyncCoordinator

    var body: some View {
        switch coordinator.status {
        case .running(let stage):
            runningView(stage: stage)
        case .error(let msg):
            Text(msg).foregroundStyle(.red).font(.caption)
        case .idle:
            idleView
        }
    }

    @ViewBuilder
    private func runningView(stage: String) -> some View {
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
    }

    @ViewBuilder
    private var idleView: some View {
        if let pending = coordinator.pendingRunSummary {
            Text("Stopped at day \(pending.completedDays) of \(pending.totalDays). Tap Sync now to continue.")
                .foregroundStyle(.secondary).font(.caption)
        } else if let r = coordinator.lastResult {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Last sync").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(r.finishedAt, style: .relative)
                        .font(.caption).foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                HStack {
                    Text("Days"); Spacer()
                    Text("\(r.totalDays)").monospacedDigit()
                }.font(.subheadline)
                HStack {
                    Text("Samples"); Spacer()
                    Text("\(r.totalSamples)").monospacedDigit()
                }.font(.subheadline)
                HStack {
                    Text("Workouts"); Spacer()
                    Text("\(r.totalWorkouts)").monospacedDigit()
                }.font(.subheadline)
            }
        } else if let last = LastSyncStore.load(for: coordinator.destination) {
            HStack {
                Text("Last sync").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(last, style: .relative)
                    .font(.caption).foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } else {
            EmptyView()
        }
    }
}
