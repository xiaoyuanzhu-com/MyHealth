import SwiftUI

/// Files-app export target. One-shot full export of all HealthKit data as
/// a zip, presented to the user via `UIDocumentPickerViewController` so they
/// can save it into any Files-app location (iCloud Drive, On My iPhone, …).
///
/// No auto-sync toggle: this is always user-initiated. No incremental
/// state: every export re-walks every day.
struct FilesDetailView: View {
    @EnvironmentObject var coordinators: SyncCoordinators

    var body: some View {
        Form {
            Section {
                ExportButton(exporter: coordinators.files)
                ExportStatusLine(exporter: coordinators.files)
            }

            Section {
                Text("Exports every HealthKit day from your first sample through today as `apple-health/YYYY/MM/DD/<type>.json` inside a single zip. After the export finishes, iOS will ask where you want to save the file — iCloud Drive, On My iPhone, or any Files-app location.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Files")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: Binding(
            get: { coordinators.files.pendingExportURL },
            set: { coordinators.files.pendingExportURL = $0 }
        )) { artifact in
            DocumentExporter(url: artifact.url)
        }
    }
}

private struct ExportButton: View {
    @ObservedObject var exporter: FilesExporter

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
    }

    private var icon: String {
        switch exporter.status {
        case .running: return "stop.fill"
        default: return "square.and.arrow.down"
        }
    }

    private var title: String {
        switch exporter.status {
        case .running: return String(localized: "Stop")
        default: return String(localized: "Export now")
        }
    }

    private func action() async {
        switch exporter.status {
        case .running:
            exporter.stop()
        case .idle, .error:
            await exporter.exportNow()
        }
    }
}

private struct ExportStatusLine: View {
    @ObservedObject var exporter: FilesExporter

    var body: some View {
        switch exporter.status {
        case .running(let stage):
            if let p = exporter.progress {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        if let date = p.currentDate {
                            Text(date)
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
            if let last = exporter.lastExportAt {
                HStack {
                    Text("Last export").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(last, style: .relative)
                        .font(.caption).foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }
}
