import XCTest
@testable import MyHealth

final class SyncCursorTests: XCTestCase {
    private let dest: Destination = .myLifeDB

    override func setUp() {
        try? FileManager.default.removeItem(at: SyncCursor.url(for: dest))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: SyncCursor.url(for: dest))
    }

    func testLoadReturnsEmptyCursorWhenFileMissing() {
        let cursor = SyncCursor.load(for: dest)
        XCTAssertNil(cursor.lastSyncedDay)
    }

    func testSaveLoadRoundTrip() throws {
        let original = SyncCursor(
            lastSyncedDay: DayBucketer.DayKey(date: "2026-05-12", timezone: "Asia/Shanghai")
        )
        try SyncCursor.save(original, for: dest)
        let loaded = SyncCursor.load(for: dest)
        XCTAssertEqual(loaded, original)
    }

    func testLoadReturnsEmptyCursorOnCorruptJSON() throws {
        try "{not valid json".data(using: .utf8)!.write(to: SyncCursor.url(for: dest), options: .atomic)
        let cursor = SyncCursor.load(for: dest)
        XCTAssertNil(cursor.lastSyncedDay)
    }

    func testPerDestinationIsolation() throws {
        let mldCursor = SyncCursor(
            lastSyncedDay: DayBucketer.DayKey(date: "2026-05-12", timezone: "UTC")
        )
        let driveCursor = SyncCursor(
            lastSyncedDay: DayBucketer.DayKey(date: "2026-05-01", timezone: "UTC")
        )
        defer {
            try? FileManager.default.removeItem(at: SyncCursor.url(for: .myLifeDB))
            try? FileManager.default.removeItem(at: SyncCursor.url(for: .googleDrive))
        }
        try SyncCursor.save(mldCursor, for: .myLifeDB)
        try SyncCursor.save(driveCursor, for: .googleDrive)
        XCTAssertEqual(SyncCursor.load(for: .myLifeDB), mldCursor)
        XCTAssertEqual(SyncCursor.load(for: .googleDrive), driveCursor)
    }
}
