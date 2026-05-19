import XCTest
@testable import MyHealth

final class SyncWindowTests: XCTestCase {

    private let tz = "Asia/Shanghai"

    private func key(_ date: String) -> DayBucketer.DayKey {
        DayBucketer.DayKey(date: date, timezone: tz)
    }

    func testFirstRun_noCursor_returnsBackfillChunkEndingToday() {
        // No prior cursor: window is [today - backfillChunkDays … today], newest-first.
        let days = SyncWindow.compute(
            today: key("2026-05-19"),
            cursor: SyncCursor(earliestSyncedDay: nil, latestSyncedDay: nil),
            earliestPermitted: key("2010-01-01"),
            recentReSyncDays: 7,
            backfillChunkDays: 30,
            timezone: tz
        )
        XCTAssertEqual(days.first?.date, "2026-05-19")
        XCTAssertEqual(days.last?.date, "2026-04-19") // 30 days back
        XCTAssertEqual(days.count, 31)               // inclusive both ends
        XCTAssertTrue(days.allSatisfy { $0.timezone == tz })
    }

    func testSubsequentRun_unionsRecentAndBackfillExtension() {
        let days = SyncWindow.compute(
            today: key("2026-05-19"),
            cursor: SyncCursor(earliestSyncedDay: key("2026-04-19"),
                               latestSyncedDay: key("2026-05-18")),
            earliestPermitted: key("2010-01-01"),
            recentReSyncDays: 7,
            backfillChunkDays: 30,
            timezone: tz
        )
        XCTAssertEqual(days.first?.date, "2026-05-19")
        XCTAssertEqual(days.last?.date, "2026-03-20")
        XCTAssertEqual(days.count, 8 + 30)
        XCTAssertFalse(days.contains { $0.date == "2026-05-11" })
        XCTAssertFalse(days.contains { $0.date == "2026-04-19" })
    }

    func testFullyBackfilled_returnsRecentWindowOnly() {
        let days = SyncWindow.compute(
            today: key("2026-05-19"),
            cursor: SyncCursor(earliestSyncedDay: key("2010-01-01"),
                               latestSyncedDay: key("2026-05-18")),
            earliestPermitted: key("2010-01-01"),
            recentReSyncDays: 7,
            backfillChunkDays: 30,
            timezone: tz
        )
        XCTAssertEqual(days.first?.date, "2026-05-19")
        XCTAssertEqual(days.last?.date, "2026-05-12")
        XCTAssertEqual(days.count, 8)
    }

    func testBackfillClampedToEarliestPermitted() {
        let days = SyncWindow.compute(
            today: key("2026-05-19"),
            cursor: SyncCursor(earliestSyncedDay: key("2026-01-03"),
                               latestSyncedDay: key("2026-05-18")),
            earliestPermitted: key("2026-01-01"),
            recentReSyncDays: 7,
            backfillChunkDays: 30,
            timezone: tz
        )
        XCTAssertEqual(days.last?.date, "2026-01-01")
        XCTAssertTrue(days.contains { $0.date == "2026-01-02" })
        XCTAssertFalse(days.contains { $0.date == "2025-12-31" })
    }

    func testNewestFirstOrdering() {
        let days = SyncWindow.compute(
            today: key("2026-05-19"),
            cursor: SyncCursor(earliestSyncedDay: nil, latestSyncedDay: nil),
            earliestPermitted: key("2010-01-01"),
            recentReSyncDays: 7,
            backfillChunkDays: 5,
            timezone: tz
        )
        for i in 1..<days.count {
            XCTAssertGreaterThan(days[i - 1].date, days[i].date,
                                 "Days must be sorted newest-first")
        }
    }

    func testRecentReSyncZero_returnsOnlyToday() {
        // recentReSyncDays = 0 means "today + 0 prior" = just today. With
        // no backfill chunk and no cursor, the result is [today] alone.
        let days = SyncWindow.compute(
            today: key("2026-05-19"),
            cursor: SyncCursor(earliestSyncedDay: nil, latestSyncedDay: nil),
            earliestPermitted: key("2010-01-01"),
            recentReSyncDays: 0,
            backfillChunkDays: 0,
            timezone: tz
        )
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days.first?.date, "2026-05-19")
    }
}
