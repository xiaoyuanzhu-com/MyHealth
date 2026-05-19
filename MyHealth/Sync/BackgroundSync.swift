import Foundation
import BackgroundTasks
import HealthKit

/// Registers and schedules MyHealth's background sync task.
///
/// iOS will only run this when the system has spare capacity (charging, on
/// Wi-Fi, idle, …). We pair it with `HKHealthStore.enableBackgroundDelivery`
/// plus an `HKObserverQuery` per monitored type so freshly-recorded data
/// (e.g. a finished workout) also triggers a sync without waiting for the
/// daily window.
enum BackgroundSync {
    static let taskIdentifier = "com.xiaoyuanzhu.MyHealth.dailySync"

    // HKObserverQuery instances must stay alive for HealthKit to keep
    // delivering wakes, and they need the same HKHealthStore that
    // `execute`d them. Both are static so they outlive any caller.
    private static let healthStore = HKHealthStore()
    private static var observerQueries: [HKObserverQuery] = []

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
        submitRefreshRequest(earliestBeginDate: Date(timeIntervalSinceNow: 23 * 60 * 60))
    }

    /// Brings the next BG sync forward — used by HKObserverQuery wakes,
    /// where the wake budget is too small to run a full sync inline.
    private static func scheduleSoon() {
        submitRefreshRequest(earliestBeginDate: Date(timeIntervalSinceNow: 60))
    }

    private static func submitRefreshRequest(earliestBeginDate: Date) {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = earliestBeginDate
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("MyHealth: failed to schedule BGAppRefreshTask: \(error)")
        }
    }

    /// Enables HealthKit background delivery AND registers the
    /// `HKObserverQuery` instances iOS needs in order to actually wake the
    /// app for new data. Per Apple, `enableBackgroundDelivery` alone is a
    /// no-op without an active observer query. Idempotent — safe to call
    /// on every launch (and we must, since observer queries don't survive
    /// process termination).
    static func enableBackgroundDelivery() {
        guard observerQueries.isEmpty else { return }
        for type in HealthDataTypes.allAnchoredSampleTypes {
            healthStore.enableBackgroundDelivery(for: type, frequency: .hourly) { _, _ in }
            let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, _ in
                // Defer the actual sync to the next BGAppRefreshTask — the
                // observer wake budget is small and the BGTask path has
                // expiration handling and resume-on-pause already wired up.
                scheduleSoon()
                completion()
            }
            healthStore.execute(query)
            observerQueries.append(query)
        }
    }

    private static func handle(task: BGAppRefreshTask) {
        scheduleNext()

        let workItem = Task { @MainActor in
            // Pure BG launches don't attach a scene, so HomeView's .task —
            // where Google sign-in is restored — never runs. Restore here
            // so Drive is included in defaultDestinations() instead of
            // being silently skipped.
            _ = await DriveAuth.restorePreviousSignIn()

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
        if WebDAVStore.load() != nil { s.insert(.webdav) }
        return s
    }
}
