import XCTest
@testable import MyHealth

final class SyncRunStateTests: XCTestCase {

    private var tmpURL: URL!

    override func setUp() {
        tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-run-state-\(UUID()).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpURL)
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
        try SyncRunStore.save(state, at: tmpURL)
        let loaded = try XCTUnwrap(SyncRunStore.load(at: tmpURL))
        XCTAssertEqual(loaded, state)
    }

    func testLoadReturnsNilWhenFileMissing() {
        XCTAssertNil(SyncRunStore.load(at: tmpURL))
    }

    func testClearRemovesFile() throws {
        let state = SyncRunState(
            runID: "x", startedAt: "x",
            daysToSync: [], completedDayIndex: 0, inProgressTypeIndex: 0
        )
        try SyncRunStore.save(state, at: tmpURL)
        XCTAssertNotNil(SyncRunStore.load(at: tmpURL))
        SyncRunStore.clear(at: tmpURL)
        XCTAssertNil(SyncRunStore.load(at: tmpURL))
    }
}
