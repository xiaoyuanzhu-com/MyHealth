import SwiftUI
import HealthKit
import UIKit

/// Data tab: "Manage Access" toolbar button + grouped list of every HealthKit
/// permission type. Tapping a row opens its detail page.
struct DataTab: View {
    @StateObject private var status = HealthAuthStatus()

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
                    Button("Manage Access") { openHealthAppSources() }
                }
            }
            .task {
                // Idempotent: HealthKit silently no-ops once every type has
                // been decided; only surfaces the sheet for newly-added types.
                try? await HealthKitAuth().requestAuthorization()
                status.refresh()
            }
        }
    }

    /// Jumps to Health → Sharing → Apps so the user can tap MyHealth and toggle
    /// individual categories. There is no public URL scheme to deep-link
    /// further (directly onto MyHealth's page); `Sources/` is the closest
    /// undocumented entry point that has held up across iOS versions. Falls
    /// back to the Health app root if Apple ever removes it.
    private func openHealthAppSources() {
        let candidates = ["x-apple-health://Sources/", "x-apple-health://"]
        for s in candidates {
            if let url = URL(string: s), UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url)
                return
            }
        }
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
