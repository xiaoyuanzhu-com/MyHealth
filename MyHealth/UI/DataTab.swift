import SwiftUI
import HealthKit
import UIKit

/// Data tab: "Manage Access" toolbar button + grouped list of every HealthKit
/// permission type. Tapping a row opens its detail page.
struct DataTab: View {
    @StateObject private var status = HealthAuthStatus()
    @State private var manageDialog = false
    @State private var manageError: String?

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
                    Button("Manage Access") { manageDialog = true }
                }
            }
            .confirmationDialog(
                "Manage HealthKit Access",
                isPresented: $manageDialog,
                titleVisibility: .visible
            ) {
                Button("Request via HealthKit") {
                    Task { await requestAccess() }
                }
                Button("Open Health App") { openHealthApp() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("HealthKit only shows the permission sheet for types you haven't been asked about. To change an existing decision, open the Health app — Profile — Apps and Services — MyHealth.")
            }
            .alert("Error", isPresented: .constant(manageError != nil)) {
                Button("OK", role: .cancel) { manageError = nil }
            } message: {
                Text(manageError ?? "")
            }
            .task { status.refresh() }
        }
    }

    private func requestAccess() async {
        do {
            try await HealthKitAuth().requestAuthorization()
            status.refresh()
        } catch {
            manageError = error.localizedDescription
        }
    }

    private func openHealthApp() {
        if let url = URL(string: "x-apple-health://"),
           UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        } else if let settings = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(settings)
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
