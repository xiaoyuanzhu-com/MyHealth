import SwiftUI
import HealthKit
import UIKit

/// Data tab: "Manage Access" toolbar button + grouped list of every HealthKit
/// permission type. Tapping a row opens its detail page.
struct DataTab: View {
    @StateObject private var status = HealthAuthStatus()
    @State private var manageSheetShown = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(HealthTypeCatalog.groups, id: \.group.id) { section in
                    Section(section.group.title) {
                        ForEach(section.entries) { entry in
                            NavigationLink(value: entry) {
                                DataTypeRow(entry: entry, requested: status.isRequested(entry.objectType))
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Data")
            .navigationDestination(for: HealthTypeEntry.self) { entry in
                DataTypeDetailView(entry: entry)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Manage Access") { manageSheetShown = true }
                }
            }
            .sheet(isPresented: $manageSheetShown) {
                ManageAccessSheet()
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
            .task {
                // Idempotent: HealthKit silently no-ops once every type has
                // been decided; only surfaces the sheet for newly-added types.
                try? await HealthKitAuth().requestAuthorization()
                status.refresh()
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

/// Snapshot of which types have been prompted at least once, recomputed
/// after each "Manage Access" tap. Pre-iOS authorization status is cached
/// here to avoid hitting `HKHealthStore.authorizationStatus` from inside
/// the view body for every row on every redraw.
@MainActor
final class HealthAuthStatus: ObservableObject {
    private let store = HKHealthStore()
    @Published private var requested: Set<String> = []

    func refresh() {
        var s: Set<String> = []
        for entry in HealthTypeCatalog.all {
            if store.authorizationStatus(for: entry.objectType) != .notDetermined {
                s.insert(entry.id)
            }
        }
        requested = s
    }

    func isRequested(_ type: HKObjectType) -> Bool {
        requested.contains(type.identifier)
    }
}

private struct DataTypeRow: View {
    let entry: HealthTypeEntry
    let requested: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.icon)
                .foregroundStyle(.tint)
                .frame(width: 28, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName)
            }
            Spacer()
            Circle()
                .fill(requested ? Color.green : Color.secondary.opacity(0.3))
                .frame(width: 8, height: 8)
                .accessibilityLabel(requested ? "Requested" : "Not requested")
        }
    }
}
