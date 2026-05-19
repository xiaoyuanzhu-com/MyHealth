import XCTest
@testable import MyHealth

final class DayBucketerTests: XCTestCase {

    func testDateInSampleTimezone() {
        // 2026-01-18T01:00:00 UTC = 2026-01-18 09:00:00 in Asia/Shanghai (UTC+8)
        let utc = Date(timeIntervalSince1970: 1768698000)
        let key = DayBucketer.dayKey(start: utc, timezone: TimeZone(identifier: "Asia/Shanghai"))
        XCTAssertEqual(key.date, "2026-01-18")
        XCTAssertEqual(key.timezone, "Asia/Shanghai")
    }

    func testCrossesMidnightInLocalTime() {
        // 2026-01-18T17:00:00 UTC = 2026-01-19 01:00:00 in Asia/Shanghai (UTC+8).
        // Should bucket to Jan 19, NOT Jan 18.
        let utc = Date(timeIntervalSince1970: 1768755600)
        let key = DayBucketer.dayKey(start: utc, timezone: TimeZone(identifier: "Asia/Shanghai"))
        XCTAssertEqual(key.date, "2026-01-19")
    }

    func testNilTimezoneFallsBackToDeviceCurrent() {
        let utc = Date(timeIntervalSince1970: 1768698000)
        let key = DayBucketer.dayKey(start: utc, timezone: nil)
        // We can't assert a specific date because TimeZone.current depends on
        // the test runner, but we CAN assert the timezone string matches.
        XCTAssertEqual(key.timezone, TimeZone.current.identifier)
    }

    func testPathComponents() {
        let key = DayBucketer.DayKey(date: "2026-01-18", timezone: "Asia/Shanghai")
        XCTAssertEqual(key.pathPrefix, "2026/01/18")
    }
}
