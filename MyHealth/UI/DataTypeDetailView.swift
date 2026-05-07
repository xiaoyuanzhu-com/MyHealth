import SwiftUI
import HealthKit

/// Detail page for a single HealthKit permission type. Shows description and
/// a paginated list of recent samples for that type (newest first).
struct DataTypeDetailView: View {
    let entry: HealthTypeEntry
    @StateObject private var loader: HealthSamplePreviewLoader

    init(entry: HealthTypeEntry) {
        self.entry = entry
        _loader = StateObject(wrappedValue: HealthSamplePreviewLoader(entry: entry))
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Image(systemName: entry.icon)
                            .font(.title)
                            .foregroundStyle(.tint)
                            .frame(width: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.displayName).font(.headline)
                            Text(entry.id).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    Text(entry.description).font(.callout).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section("Recent samples") {
                if !loader.canPreview {
                    Text("No preview available for this type.")
                        .foregroundStyle(.secondary).font(.callout)
                } else if loader.rows.isEmpty && !loader.isLoading {
                    Text("No data found.")
                        .foregroundStyle(.secondary).font(.callout)
                } else {
                    ForEach(loader.rows) { row in
                        SampleRowView(row: row)
                            .onAppear {
                                if row.id == loader.rows.last?.id {
                                    Task { await loader.loadNextPage() }
                                }
                            }
                    }
                    if loader.isLoading {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    }
                    if !loader.hasMore && !loader.rows.isEmpty {
                        Text("End of data")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }

            if let error = loader.errorMessage {
                Section {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(entry.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if loader.rows.isEmpty { await loader.loadNextPage() }
        }
    }
}

private struct SampleRowView: View {
    let row: SamplePreviewRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.primaryText).font(.body)
                Spacer()
                Text(row.startDate, style: .date)
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if let secondary = row.secondaryText {
                    Text(secondary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(row.startDate, style: .time)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
