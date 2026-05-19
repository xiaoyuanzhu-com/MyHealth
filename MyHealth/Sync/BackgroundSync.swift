import Foundation
import BackgroundTasks
import HealthKit

/// Registers and schedules MyHealth's background sync task.
///
/// iOS will only run this when the system has spare capacity (charging, on
/// Wi-Fi, idle, …). We pair it with `HKObserverQuery.enableBackgroundDelivery`
/// so freshly-recorded workouts also trigger a sync without waiting for the
/// daily window.
enum BackgroundSync {
    static let taskIdentifier = "org.foss.myhealth.ios.dailySync"

    /// Call from `applicationDidFinishLaunching` (App init) — registration must
    /// happen before the first responder runloop turn after launch.
    static func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { task in
            handle(task: task as! BGAppRefreshTask)
        }
    }

    /// Schedules the next run ~24h from now. Re-call after every sync.
    static func scheduleNext() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 23 * 60 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("MyHealth: failed to schedule BGAppRefreshTask: \(error)")
        }
    }

    /// Asks HealthKit to wake the app when new data of any monitored type
    /// arrives. iOS coalesces these wakes — we still rely on the daily timer
    /// as a safety net.
    static func enableBackgroundDelivery() {
        let store = HKHealthStore()
        for type in HealthDataTypes.allAnchoredSampleTypes {
            store.enableBackgroundDelivery(for: type, frequency: .hourly) { _, _ in }
        }
    }

    private static func handle(task: BGAppRefreshTask) {
        scheduleNext()

        let workItem = Task { @MainActor in
            let coordinator = SyncCoordinator()
            await coordinator.runOnce(enabledDestinations: defaultDestinations())
            // A clean finish AND a stop-on-expiration both land at .idle
            // (stop persists the (day, type) checkpoint; the next run
            // resumes from it). Both count as graceful so iOS doesn't
            // deprioritize future BG slots.
            switch coordinator.status {
            case .idle: return true
            case .running, .error: return false
            }
        }
        task.expirationHandler = {
            // Stop gracefully rather than cancel — SyncCoordinator will
            // checkpoint state at the next (day, type) boundary so the
            // next run (BG or foreground) resumes from where we left off.
            Task { @MainActor in SyncCoordinator.currentlyActive?.stop() }
        }
        Task {
            let success = (try? await workItem.value) ?? false
            task.setTaskCompleted(success: success)
        }
    }

    @MainActor
    private static func defaultDestinations() -> Set<SyncCoordinator.Destination> {
        var s: Set<SyncCoordinator.Destination> = []
        if (try? TokenStore.load()) != nil { s.insert(.myLifeDB) }
        if DriveAuth.currentUser != nil { s.insert(.googleDrive) }
        return s
    }
}
