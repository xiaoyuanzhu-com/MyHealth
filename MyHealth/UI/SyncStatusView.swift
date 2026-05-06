import SwiftUI

/// Compact header strip showing the coordinator's current state.
struct SyncStatusView: View {
    @EnvironmentObject var coordinator: SyncCoordinator

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
            VStack(alignment: .leading) {
                Text(headline).font(.headline)
                if let sub = subline {
                    Text(sub).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding()
        .background(backgroundColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch coordinator.status {
        case .idle:
            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).font(.title)
        case .running:
            ProgressView()
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.title)
        }
    }

    private var headline: String {
        switch coordinator.status {
        case .idle:
            if coordinator.lastResult != nil { return "Up to date" }
            return "Ready"
        case .running(let stage): return stage
        case .error: return "Sync failed"
        }
    }

    private var subline: String? {
        if case .error(let msg) = coordinator.status { return msg }
        if let r = coordinator.lastResult {
            return "Batch \(r.batchID) · \(r.finishedAt.formatted(date: .omitted, time: .shortened))"
        }
        return nil
    }

    private var backgroundColor: Color {
        switch coordinator.status {
        case .idle: return .green
        case .running: return .blue
        case .error: return .red
        }
    }
}
