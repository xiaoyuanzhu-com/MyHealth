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
        XCTAssertNil(cursor.lastSyncedDay)
    }

    func testSaveLoadRoundTrip() throws {
        let original = SyncCursor(
            lastSyncedDay: DayBucketer.DayKey(date: "2026-05-12", timezone: "Asia/Shanghai")
        )
        try SyncCursor.save(original, at: tmpURL)
        let loaded = SyncCursor.load(at: tmpURL)
        XCTAssertEqual(loaded, original)
    }

    func testLoadReturnsEmptyCursorOnCorruptJSON() throws {
        try "{not valid json".data(using: .utf8)!.write(to: tmpURL, options: .atomic)
        let cursor = SyncCursor.load(at: tmpURL)
        XCTAssertNil(cursor.lastSyncedDay)
    }
}
