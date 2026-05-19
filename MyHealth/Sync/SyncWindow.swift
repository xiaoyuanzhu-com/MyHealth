import Foundation

/// Decides which days a sync run should cover and in what order.
/// Pure: no I/O, no HealthKit.
///
/// A run has two phases, emitted in this order in the output:
///
/// 1. **Forward** (oldest → newest): `[lastSyncedDay … today]`, inclusive of
///    the anchor itself (re-syncs the anchor day in case data landed in it
///    after the previous run finished). On first run (no anchor) the caller
///    supplies `oldestDataDay` discovered from HealthKit, and forward covers
///    `[oldestDataDay … today]` with no double-check phase.
///
/// 2. **Double-check** (backward, newer-of-old → oldest-of-old):
///    `doubleCheckDays` entries strictly older than `lastSyncedDay`. Catches
///    backfills / edits made to recently-synced days. Skipped on first run.
///
/// Each entry carries its phase so the coordinator can pick the right
/// status string and (in future) different optimization strategies.
enum SyncWindow {

    enum Phase: String, Codable, Equatable {
        case forward
        case doubleCheck
    }

    struct Entry: Codable, Equatable {
        let key: DayBucketer.DayKey
        let phase: Phase
    }

    /// Forward + double-check days, in execution order. Empty only if
    /// `today < lastSyncedDay` (clock skew — caller should treat as no-op).
    ///
    /// Parameters:
    ///   - today: the current day in `timezone`.
    ///   - cursor: persistent watermark (`lastSyncedDay`). nil ⇒ first run.
    ///   - oldestDataDay: only consulted on first run; the earliest day with
    ///     any HealthKit data. Caller probes HealthKit to compute this.
    ///   - doubleCheckDays: number of days to re-verify backward (e.g. 7).
    ///   - earliestPermitted: clamp for the very oldest day we will ever
    ///     query (typically `HKHealthStore.earliestPermittedSampleDate()`).
    static func compute(
        today: DayBucketer.DayKey,
        cursor: SyncCursor,
        oldestDataDay: DayBucketer.DayKey?,
        doubleCheckDays: Int,
        earliestPermitted: DayBucketer.DayKey,
        timezone: String
    ) -> [Entry] {
        let dayMath = DayMath(timezone: timezone)
        var entries: [Entry] = []

        // Phase 1: forward.
        let forwardStart: DayBucketer.DayKey
        if let anchor = cursor.lastSyncedDay {
            forwardStart = anchor
        } else if let oldest = oldestDataDay {
            forwardStart = clampToPermitted(oldest, earliestPermitted: earliestPermitted)
        } else {
            // No anchor AND no oldest-data probe: caller didn't supply one
            // (e.g. HealthKit denied authorization). Fall back to today-only.
            forwardStart = today
        }
        for day in inclusiveRange(from: forwardStart, to: today, dayMath: dayMath) {
            entries.append(Entry(key: day, phase: .forward))
        }

        // Phase 2: double-check (skipped on first run).
        if let anchor = cursor.lastSyncedDay {
            var cursorDay = dayMath.previousDay(anchor)
            for _ in 0..<doubleCheckDays {
                if cursorDay.date < earliestPermitted.date { break }
                entries.append(Entry(key: cursorDay, phase: .doubleCheck))
                cursorDay = dayMath.previousDay(cursorDay)
            }
        }

        return entries
    }

    // MARK: - private

    /// `[from, from+1, …, to]` inclusive both ends, oldest→newest. Returns
    /// `[]` if `to < from` (clock skew or weird timezone hop).
    private static func inclusiveRange(
        from: DayBucketer.DayKey,
        to: DayBucketer.DayKey,
        dayMath: DayMath
    ) -> [DayBucketer.DayKey] {
        guard from.date <= to.date else { return [] }
        var out: [DayBucketer.DayKey] = []
        var cursor = from
        // Hard cap to defend against pathological inputs (e.g. anchor
        // somehow >100 years old). Each sync run should never legitimately
        // exceed this.
        let cap = 50_000
        var i = 0
        while cursor.date <= to.date {
            out.append(cursor)
            if cursor.date == to.date { break }
            cursor = dayMath.nextDay(cursor)
            i += 1
            if i >= cap { break }
        }
        return out
    }

    private static func clampToPermitted(
        _ k: DayBucketer.DayKey,
        earliestPermitted: DayBucketer.DayKey
    ) -> DayBucketer.DayKey {
        k.date < earliestPermitted.date ? earliestPermitted : k
    }

    /// Reusable date arithmetic in a fixed timezone.
    private struct DayMath {
        let calendar: Calendar
        let formatter: DateFormatter
        let timezone: String

        init(timezone: String) {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: timezone) ?? .current
            self.calendar = cal
            let f = DateFormatter()
            f.calendar = cal
            f.timeZone = cal.timeZone
            f.dateFormat = "yyyy-MM-dd"
            self.formatter = f
            self.timezone = timezone
        }

        func previousDay(_ k: DayBucketer.DayKey) -> DayBucketer.DayKey {
            shifted(k, by: -1)
        }

        func nextDay(_ k: DayBucketer.DayKey) -> DayBucketer.DayKey {
            shifted(k, by: 1)
        }

        private func shifted(_ k: DayBucketer.DayKey, by days: Int) -> DayBucketer.DayKey {
            guard let date = formatter.date(from: k.date),
                  let moved = calendar.date(byAdding: .day, value: days, to: date)
            else { return k }
            return DayBucketer.DayKey(date: formatter.string(from: moved), timezone: timezone)
        }
    }
}
