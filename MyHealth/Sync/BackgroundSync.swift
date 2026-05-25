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
            // so Drive is included in the enabled set instead of being
            // silently skipped.
            _ = await DriveAuth.restorePreviousSignIn()

            let destinations = enabledDestinations()
            if destinations.isEmpty {
                return true
            }

            // Run each destination sequentially with its own coordinator.
            // Sequential keeps HKHealthStore pressure bounded and means
            // expiration only needs to stop the one currently in-flight.
            // Coordinators share `HKHealthStore` happily but we don't gain
            // much from parallel runs in the BG window — daily diffs are
            // small.
            var allClean = true
            for destination in destinations {
                let coordinator = SyncCoordinator(destination: destination)
                await coordinator.runOnce()
                switch coordinator.status {
                case .idle: continue
                case .running, .error: allClean = false
                }
            }
            // A clean finish AND a stop-on-expiration both land at .idle
            // (stop persists the (day, type) checkpoint; the next run
            // resumes from it). Either counts as graceful so iOS doesn't
            // deprioritize future BG slots.
            return allClean
        }
        task.expirationHandler = {
            // Stop gracefully rather than cancel — each coordinator will
            // checkpoint state at the next (day, type) boundary so the
            // next run (BG or foreground) resumes from where we left off.
            Task { @MainActor in
                for c in SyncCoordinator.allActive { c.stop() }
            }
        }
        Task {
            let success = (try? await workItem.value) ?? false
            task.setTaskCompleted(success: success)
        }
    }

    /// Destinations that should run in this background pass: must have
    /// credentials AND have their per-target auto-sync flag enabled.
    @MainActor
    private static func enabledDestinations() -> [Destination] {
        let defaults = UserDefaults.standard
        var out: [Destination] = []
        if defaults.object(forKey: "autoSyncMyLifeDB") as? Bool ?? true,
           (try? TokenStore.load()) != nil {
            out.append(.myLifeDB)
        }
        if defaults.object(forKey: "autoSyncGoogleDrive") as? Bool ?? true,
           DriveAuth.currentUser != nil {
            out.append(.googleDrive)
        }
        if defaults.object(forKey: "autoSyncWebDAV") as? Bool ?? true,
           WebDAVStore.load() != nil {
            out.append(.webdav)
        }
        return out
    }
}
