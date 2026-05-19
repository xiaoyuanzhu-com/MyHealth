import Foundation

/// Decides which days a sync run should cover, given the persistent cursor
/// and the current date. Pure: no I/O, no HealthKit. Output is newest-first.
///
/// Policy = recent re-sync window ∪ backfill chunk.
///   - The recent window covers `[today - recentReSyncDays … today]` (inclusive
///     both ends, i.e. recentReSyncDays + 1 entries) to catch Apple-Watch /
///     manual backfills.
///   - On first run (cursor.earliestSyncedDay == nil), the backfill segment
///     primes history by emitting `backfillChunkDays` days older than today.
///   - On subsequent runs, the backfill segment extends history older than
///     `cursor.earliestSyncedDay` by `backfillChunkDays`, until
///     `earliestPermitted` is reached.
///
/// The two segments are typically NOT contiguous — the middle of already-
/// backfilled history is skipped to keep runs short. Overlap (e.g. first run
/// where the segments meet) is handled by deduping.
enum SyncWindow {

    static func compute(
        today: DayBucketer.DayKey,
        cursor: SyncCursor,
        earliestPermitted: DayBucketer.DayKey,
        recentReSyncDays: Int,
        backfillChunkDays: Int,
        timezone: String
    ) -> [DayBucketer.DayKey] {
        let dayMath = DayMath(timezone: timezone)
        let recent = recentSegment(today: today, days: recentReSyncDays,
                                   earliestPermitted: earliestPermitted, dayMath: dayMath)
        let backfill = backfillSegment(today: today, cursor: cursor, chunk: backfillChunkDays,
                                       earliestPermitted: earliestPermitted, dayMath: dayMath)
        var seen = Set<String>()
        var out: [DayBucketer.DayKey] = []
        for k in recent + backfill where !seen.contains(k.date) {
            seen.insert(k.date)
            out.append(k)
        }
        out.sort { $0.date > $1.date }
        return out
    }

    // MARK: - private

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
            guard let date = formatter.date(from: k.date),
                  let prev = calendar.date(byAdding: .day, value: -1, to: date)
            else { return k }
            return DayBucketer.DayKey(date: formatter.string(from: prev), timezone: timezone)
        }
    }

    /// `[today, today-1, ..., today - days]`, inclusive both ends → `days + 1`
    /// entries. Clamped to earliestPermitted.
    private static func recentSegment(
        today: DayBucketer.DayKey,
        days: Int,
        earliestPermitted: DayBucketer.DayKey,
        dayMath: DayMath
    ) -> [DayBucketer.DayKey] {
        var out: [DayBucketer.DayKey] = []
        var cursor = today
        for _ in 0..<(days + 1) {
            out.append(cursor)
            if cursor.date <= earliestPermitted.date { break }
            cursor = dayMath.previousDay(cursor)
        }
        return out
    }

    /// First run (cursor.earliestSyncedDay == nil):
    ///   `[today - 1, today - 2, ..., today - chunk]` — primes history below today.
    /// Subsequent runs:
    ///   `[earliestSyncedDay - 1, ..., earliestSyncedDay - chunk]` — extends backfill.
    /// Fully backfilled (earliestSyncedDay <= earliestPermitted): returns `[]`.
    /// Always clamped to earliestPermitted.
    private static func backfillSegment(
        today: DayBucketer.DayKey,
        cursor: SyncCursor,
        chunk: Int,
        earliestPermitted: DayBucketer.DayKey,
        dayMath: DayMath
    ) -> [DayBucketer.DayKey] {
        let startBoundary: DayBucketer.DayKey
        if let earliest = cursor.earliestSyncedDay {
            if earliest.date <= earliestPermitted.date { return [] }
            startBoundary = dayMath.previousDay(earliest)
        } else {
            startBoundary = dayMath.previousDay(today)
        }
        var out: [DayBucketer.DayKey] = []
        var c = startBoundary
        for _ in 0..<chunk {
            out.append(c)
            if c.date <= earliestPermitted.date { break }
            c = dayMath.previousDay(c)
        }
        return out
    }
}
