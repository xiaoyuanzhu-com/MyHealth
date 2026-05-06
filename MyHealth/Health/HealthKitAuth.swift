import Foundation
import HealthKit

enum HealthKitAuthError: Error {
    case notAvailable
}

/// Wraps the one-time HealthKit permission grant. We only ever request *read*
/// access — MyHealth never writes to HealthKit.
struct HealthKitAuth {
    let store: HKHealthStore

    init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }

    /// Triggers Apple's permission sheet listing every supported type. The
    /// request is idempotent: subsequent calls are no-ops once granted.
    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitAuthError.notAvailable
        }
        try await store.requestAuthorization(
            toShare: [],
            read: HealthDataTypes.allReadTypes
        )
    }

    /// HealthKit deliberately hides per-type read authorization status to
    /// prevent fingerprinting which conditions a user has. We can only check
    /// *write* status. The closest signal of "the user said no" is an empty
    /// query — handled by the sync coordinator.
    var hasEverPrompted: Bool {
        // We treat "any type with non-notDetermined write status" as a proxy
        // for "the sheet has been shown once". This is best-effort.
        for t in HealthDataTypes.allQuantityTypes {
            if store.authorizationStatus(for: t) != .notDetermined { return true }
        }
        return false
    }
}
