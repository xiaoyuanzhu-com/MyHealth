import XCTest
@testable import MyHealth

final class SyncCursorTests: XCTestCase {

    private var tmpURL: URL!

    override func setUp() {
        tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-cursor-\(UUID()).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpURL)
    }

    func testLoadReturnsEmptyCursorWhenFileMissing() {
        let cursor = SyncCursor.load(at: tmpURL)
        XCTAssertNil(cursor.earliestSyncedDay)
        XCTAssertNil(cursor.latestSyncedDay)
    }

    func testSaveLoadRoundTrip() throws {
        let original = SyncCursor(
            earliestSyncedDay: DayBucketer.DayKey(date: "2026-04-19", timezone: "Asia/Shanghai"),
            latestSyncedDay:   DayBucketer.DayKey(date: "2026-05-18", timezone: "Asia/Shanghai")
        )
        try SyncCursor.save(original, at: tmpURL)
        let loaded = SyncCursor.load(at: tmpURL)
        XCTAssertEqual(loaded, original)
    }

    func testAdvanceExtendsBothEnds() {
        var cursor = SyncCursor(
            earliestSyncedDay: DayBucketer.DayKey(date: "2026-04-19", timezone: "Asia/Shanghai"),
            latestSyncedDay:   DayBucketer.DayKey(date: "2026-05-18", timezone: "Asia/Shanghai")
        )
        cursor.advance(coveredDays: [
            DayBucketer.DayKey(date: "2026-05-19", timezone: "Asia/Shanghai"),
            DayBucketer.DayKey(date: "2026-05-12", timezone: "Asia/Shanghai"),
            DayBucketer.DayKey(date: "2026-04-18", timezone: "Asia/Shanghai"),
            DayBucketer.DayKey(date: "2026-03-20", timezone: "Asia/Shanghai"),
        ])
        XCTAssertEqual(cursor.latestSyncedDay?.date, "2026-05-19")
        XCTAssertEqual(cursor.earliestSyncedDay?.date, "2026-03-20")
    }

    func testAdvanceFromEmpty() {
        var cursor = SyncCursor(earliestSyncedDay: nil, latestSyncedDay: nil)
        cursor.advance(coveredDays: [
            DayBucketer.DayKey(date: "2026-05-19", timezone: "Asia/Shanghai"),
            DayBucketer.DayKey(date: "2026-04-19", timezone: "Asia/Shanghai"),
        ])
        XCTAssertEqual(cursor.latestSyncedDay?.date, "2026-05-19")
        XCTAssertEqual(cursor.earliestSyncedDay?.date, "2026-04-19")
    }

    func testAdvanceSingleDayMonotonicNoOp() {
        // A single day already inside the synced range should not move either cursor.
        var cursor = SyncCursor(
            earliestSyncedDay: DayBucketer.DayKey(date: "2026-04-19", timezone: "Asia/Shanghai"),
            latestSyncedDay:   DayBucketer.DayKey(date: "2026-05-18", timezone: "Asia/Shanghai")
        )
        cursor.advance(coveredDays: [
            DayBucketer.DayKey(date: "2026-05-01", timezone: "Asia/Shanghai")
        ])
        XCTAssertEqual(cursor.latestSyncedDay?.date, "2026-05-18")
        XCTAssertEqual(cursor.earliestSyncedDay?.date, "2026-04-19")
    }

    func testLoadReturnsEmptyCursorOnCorruptJSON() throws {
        // Garbage on disk should not crash; load() returns an empty cursor.
        try "{not valid json".data(using: .utf8)!.write(to: tmpURL, options: .atomic)
        let cursor = SyncCursor.load(at: tmpURL)
        XCTAssertNil(cursor.earliestSyncedDay)
        XCTAssertNil(cursor.latestSyncedDay)
    }
}
