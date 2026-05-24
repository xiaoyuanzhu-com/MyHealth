import SwiftUI
import HealthKit

/// Data tab: grouped list of every HealthKit permission type. Tapping a row
/// opens its detail page. "Manage Access" lives in the Sync tab's Settings.
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
            .navigationDestination(for: HealthTypeEntry.self) { entry in
                DataTypeDetailView(entry: entry)
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
