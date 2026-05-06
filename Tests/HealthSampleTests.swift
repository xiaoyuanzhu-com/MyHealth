import XCTest
@testable import MyHealth

/// Verifies the JSONL row schema stays byte-compatible with
/// `myhealth.apple_health.v1` (the previous Python CLI's output) so existing
/// downstream tooling keeps working.
final class HealthSampleTests: XCTestCase {

    func testV1RecordEncoding() throws {
        let sample = HealthSample(
            _kind: .record,
            type: "HKQuantityTypeIdentifierStepCount",
            unit: "count",
            value: "42",
            start_date: "2026-05-01 09:00:00 +0000",
            end_date: "2026-05-01 10:00:00 +0000",
            creation_date: "2026-05-01 10:00:00 +0000",
            source_name: "iPhone",
            source_version: "17.4",
            device: nil,
            uuid: "00000000-0000-0000-0000-000000000001"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(sample)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        // Required v1 keys (snake_case) must all be present.
        XCTAssertTrue(json.contains("\"_kind\":\"Record\""))
        XCTAssertTrue(json.contains("\"type\":\"HKQuantityTypeIdentifierStepCount\""))
        XCTAssertTrue(json.contains("\"unit\":\"count\""))
        XCTAssertTrue(json.contains("\"value\":\"42\""))
        XCTAssertTrue(json.contains("\"start_date\":\"2026-05-01 09:00:00 +0000\""))
        XCTAssertTrue(json.contains("\"end_date\":\"2026-05-01 10:00:00 +0000\""))
        XCTAssertTrue(json.contains("\"creation_date\":\"2026-05-01 10:00:00 +0000\""))
        XCTAssertTrue(json.contains("\"source_name\":\"iPhone\""))
    }

    func testStringifyMatchesXMLExportConvention() {
        // Integers should not gain a ".0" suffix — the XML export emits "42",
        // not "42.0".
        XCTAssertEqual(SampleEncoder.stringify(42.0), "42")
        XCTAssertEqual(SampleEncoder.stringify(0.0), "0")
        // Fractional values keep precision.
        XCTAssertTrue(SampleEncoder.stringify(72.5).contains("72.5"))
    }

    func testDateFormatterMatchesXMLExport() {
        let date = Date(timeIntervalSince1970: 1746090000) // 2025-05-01 09:00 UTC (sample)
        let formatted = SampleEncoder.format(date)
        // Shape "yyyy-MM-dd HH:mm:ss xxxx"
        XCTAssertEqual(formatted.count, 25)
        XCTAssertTrue(formatted.hasSuffix(" +0000"))
    }
}
