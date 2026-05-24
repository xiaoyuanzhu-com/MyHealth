import SwiftUI
import HealthKit
import UIKit

/// Detail page for a single HealthKit permission type. Shows description and
/// a paginated list of recent samples for that type (newest first). Tap a
/// row to inspect the sample's underlying JSON.
struct DataTypeDetailView: View {
    let entry: HealthTypeEntry
    @StateObject private var loader: HealthSamplePreviewLoader
    @State private var selectedRow: SamplePreviewRow?

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
                        Button {
                            selectedRow = row
                        } label: {
                            SampleRowView(row: row)
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
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
        .sheet(item: $selectedRow) { row in
            SampleJSONSheet(row: row)
        }
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

/// Modal sheet showing the pretty-printed DTO JSON for a single sample.
/// The text is selectable; the toolbar copy button puts the full document
/// on the pasteboard.
private struct SampleJSONSheet: View {
    let row: SamplePreviewRow
    @Environment(\.dismiss) private var dismiss

    private var hasJSON: Bool { !row.json.isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView([.vertical, .horizontal]) {
                Text(hasJSON ? row.json : String(localized: "No JSON preview available for this sample type."))
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Sample JSON")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        UIPasteboard.general.string = row.json
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .disabled(!hasJSON)
                    .accessibilityLabel("Copy JSON")
                }
            }
        }
    }
}
