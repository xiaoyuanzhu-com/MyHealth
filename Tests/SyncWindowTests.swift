import XCTest
@testable import MyHealth

final class SyncWindowTests: XCTestCase {

    private let tz = "Asia/Shanghai"

    private func key(_ date: String) -> DayBucketer.DayKey {
        DayBucketer.DayKey(date: date, timezone: tz)
    }

    // MARK: - First run

    func testFirstRun_walksFromOldestDataDayToToday_noDoubleCheck() {
        let entries = SyncWindow.compute(
            today: key("2026-05-19"),
            cursor: SyncCursor(lastSyncedDay: nil),
            oldestDataDay: key("2024-08-01"),
            doubleCheckDays: 7,
            earliestPermitted: key("2010-01-01"),
            timezone: tz
        )
        XCTAssertEqual(entries.first?.key.date, "2024-08-01")
        XCTAssertEqual(entries.first?.phase, .forward)
        XCTAssertEqual(entries.last?.key.date, "2026-05-19")
        XCTAssertEqual(entries.last?.phase, .forward)
        XCTAssertTrue(entries.allSatisfy { $0.phase == .forward },
                      "First run has no double-check phase")
    }

    func testFirstRun_noOldestDataDay_fallsBackToToday() {
        // HK auth denied → caller passes nil. Sync should still produce
        // a (degenerate) single-day forward run rather than crash.
        let entries = SyncWindow.compute(
            today: key("2026-05-19"),
            cursor: SyncCursor(lastSyncedDay: nil),
            oldestDataDay: nil,
            doubleCheckDays: 7,
            earliestPermitted: key("2010-01-01"),
            timezone: tz
        )
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.key.date, "2026-05-19")
        XCTAssertEqual(entries.first?.phase, .forward)
    }

    func testFirstRun_clampsOldestToEarliestPermitted() {
        let entries = SyncWindow.compute(
            today: key("2010-01-05"),
            cursor: SyncCursor(lastSyncedDay: nil),
            oldestDataDay: key("1990-06-15"),
            doubleCheckDays: 7,
            earliestPermitted: key("2010-01-01"),
            timezone: tz
        )
        XCTAssertEqual(entries.first?.key.date, "2010-01-01")
        XCTAssertEqual(entries.last?.key.date, "2010-01-05")
        XCTAssertEqual(entries.count, 5)
    }

    // MARK: - Subsequent runs

    func testSubsequentRun_forwardFromAnchor_thenDoubleCheckBackward() {
        // Anchor 05-12, today 05-19, doubleCheck=7.
        // Forward: 05-12, 05-13, …, 05-19 (8 entries, inclusive anchor)
        // DoubleCheck: 05-11, 05-10, …, 05-05 (7 entries, newest-of-old first)
        let entries = SyncWindow.compute(
            today: key("2026-05-19"),
            cursor: SyncCursor(lastSyncedDay: key("2026-05-12")),
            oldestDataDay: nil,
            doubleCheckDays: 7,
            earliestPermitted: key("2010-01-01"),
            timezone: tz
        )

        let forward = entries.filter { $0.phase == .forward }
        let doubleCheck = entries.filter { $0.phase == .doubleCheck }

        XCTAssertEqual(forward.count, 8)
        XCTAssertEqual(forward.first?.key.date, "2026-05-12") // anchor included
        XCTAssertEqual(forward.last?.key.date, "2026-05-19")  // ends at today
        // Forward strictly ascending.
        for i in 1..<forward.count {
            XCTAssertLessThan(forward[i - 1].key.date, forward[i].key.date)
        }

        XCTAssertEqual(doubleCheck.count, 7)
        XCTAssertEqual(doubleCheck.first?.key.date, "2026-05-11") // anchor - 1
        XCTAssertEqual(doubleCheck.last?.key.date, "2026-05-05")  // anchor - 7
        // Double-check strictly descending.
        for i in 1..<doubleCheck.count {
            XCTAssertGreaterThan(doubleCheck[i - 1].key.date, doubleCheck[i].key.date)
        }

        // Overall: forward block appears before double-check block.
        XCTAssertEqual(entries.firstIndex(where: { $0.phase == .doubleCheck }), 8)
    }

    func testSubsequentRun_sameDay_singleForwardDayPlusDoubleCheck() {
        // User syncs twice on the same day. Anchor = today. Forward = [today].
        let entries = SyncWindow.compute(
            today: key("2026-05-19"),
            cursor: SyncCursor(lastSyncedDay: key("2026-05-19")),
            oldestDataDay: nil,
            doubleCheckDays: 7,
            earliestPermitted: key("2010-01-01"),
            timezone: tz
        )
        let forward = entries.filter { $0.phase == .forward }
        let doubleCheck = entries.filter { $0.phase == .doubleCheck }
        XCTAssertEqual(forward.count, 1)
        XCTAssertEqual(forward.first?.key.date, "2026-05-19")
        XCTAssertEqual(doubleCheck.count, 7)
        XCTAssertEqual(doubleCheck.first?.key.date, "2026-05-18")
    }

    func testSubsequentRun_doubleCheckClampedToEarliestPermitted() {
        // Anchor 2010-01-03, today 2010-01-04. Double-check window of 7 would
        // try 2010-01-02, 2010-01-01, 2009-12-31, … — but earliestPermitted
        // clamps it to just 01-02 and 01-01.
        let entries = SyncWindow.compute(
            today: key("2010-01-04"),
            cursor: SyncCursor(lastSyncedDay: key("2010-01-03")),
            oldestDataDay: nil,
            doubleCheckDays: 7,
            earliestPermitted: key("2010-01-01"),
            timezone: tz
        )
        let doubleCheck = entries.filter { $0.phase == .doubleCheck }
        XCTAssertEqual(doubleCheck.map { $0.key.date }, ["2010-01-02", "2010-01-01"])
    }

    func testSubsequentRun_doubleCheckZero_returnsForwardOnly() {
        let entries = SyncWindow.compute(
            today: key("2026-05-19"),
            cursor: SyncCursor(lastSyncedDay: key("2026-05-12")),
            oldestDataDay: nil,
            doubleCheckDays: 0,
            earliestPermitted: key("2010-01-01"),
            timezone: tz
        )
        XCTAssertTrue(entries.allSatisfy { $0.phase == .forward })
        XCTAssertEqual(entries.count, 8)
    }
}
