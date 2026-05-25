import XCTest
@testable import MyHealth

final class SyncRunStateTests: XCTestCase {
    private let dest: Destination = .myLifeDB

    override func setUp() {
        SyncRunStore.clear(for: dest)
    }

    override func tearDown() {
        SyncRunStore.clear(for: dest)
    }

    func testRoundTrip() throws {
        let days = [
            DayBucketer.DayKey(date: "2026-05-19", timezone: "Asia/Shanghai"),
            DayBucketer.DayKey(date: "2026-05-18", timezone: "Asia/Shanghai"),
        ]
        let state = SyncRunState(
            runID: "20260519T120000Z",
            startedAt: "2026-05-19T12:00:00Z",
            daysToSync: days,
            completedDayIndex: 1,
            inProgressTypeIndex: 45
        )
        try SyncRunStore.save(state, for: dest)
        let loaded = try XCTUnwrap(SyncRunStore.load(for: dest))
        XCTAssertEqual(loaded, state)
    }

    func testLoadReturnsNilWhenFileMissing() {
        XCTAssertNil(SyncRunStore.load(for: dest))
    }

    func testClearRemovesFile() throws {
        let state = SyncRunState(
            runID: "x", startedAt: "x",
            daysToSync: [], completedDayIndex: 0, inProgressTypeIndex: 0
        )
        try SyncRunStore.save(state, for: dest)
        XCTAssertNotNil(SyncRunStore.load(for: dest))
        SyncRunStore.clear(for: dest)
        XCTAssertNil(SyncRunStore.load(for: dest))
    }
}
