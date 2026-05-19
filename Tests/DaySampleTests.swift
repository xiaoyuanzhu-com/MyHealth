import XCTest
@testable import MyHealth

final class DaySampleTests: XCTestCase {

    private let enc: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    func testQuantitySampleEncodesAllFields() throws {
        let s = QuantitySample(
            start: "2026-01-17T16:37:10.901Z",
            end: "2026-01-17T16:46:20.452Z",
            value: 200,
            unit: "count",
            type: "HKQuantityTypeIdentifierStepCount",
            source: "com.apple.health.37928A11",
            device: "Watch7,1",
            metadata: nil
        )
        let json = try String(data: enc.encode(s), encoding: .utf8) ?? ""
        XCTAssertEqual(json, #"{"device":"Watch7,1","end":"2026-01-17T16:46:20.452Z","source":"com.apple.health.37928A11","start":"2026-01-17T16:37:10.901Z","type":"HKQuantityTypeIdentifierStepCount","unit":"count","value":200}"#)
    }

    func testQuantitySampleOmitsAbsentDeviceAndMetadata() throws {
        let s = QuantitySample(
            start: "2026-01-17T16:37:10.901Z",
            end: "2026-01-17T16:46:20.452Z",
            value: 72.5,
            unit: "count/min",
            type: "HKQuantityTypeIdentifierHeartRate",
            source: "com.apple.health",
            device: nil,
            metadata: nil
        )
        let json = try String(data: enc.encode(s), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("\"device\""))
        XCTAssertFalse(json.contains("\"metadata\""))
        XCTAssertTrue(json.contains("\"value\":72.5"))
    }

    func testCategorySampleHasStringValue() throws {
        let s = CategorySample(
            start: "2026-01-17T17:24:19.656Z",
            end: "2026-01-17T17:27:49.348Z",
            value: "asleepCore",
            type: "HKCategoryTypeIdentifierSleepAnalysis",
            source: "com.apple.health",
            device: "Watch7,1",
            metadata: ["HKTimeZone": .string("Asia/Shanghai")]
        )
        let data = try enc.encode(s)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains(#""value":"asleepCore""#))
        XCTAssertTrue(json.contains(#""metadata":{"HKTimeZone":"Asia/Shanghai"}"#))
    }

    func testDayFileQuantityEnvelope() throws {
        let envelope = DayFile.quantity(
            date: "2026-01-18",
            type: "HKQuantityTypeIdentifierStepCount",
            timezone: "Asia/Shanghai",
            unit: "count",
            samples: []
        )
        let json = try String(data: enc.encode(envelope), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains(#""date":"2026-01-18""#))
        XCTAssertTrue(json.contains(#""timezone":"Asia/Shanghai""#))
        XCTAssertTrue(json.contains(#""unit":"count""#))
        XCTAssertTrue(json.contains(#""samples":[]"#))
    }

    func testDayFileCategoryEnvelopeOmitsUnit() throws {
        let envelope = DayFile.category(
            date: "2026-01-18",
            type: "HKCategoryTypeIdentifierSleepAnalysis",
            timezone: "Asia/Shanghai",
            samples: []
        )
        let json = try String(data: enc.encode(envelope), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("\"unit\""))
    }

    func testWorkoutFileEncodesRouteAndStats() throws {
        let wf = WorkoutFile(
            uuid: "A1B2C3D4",
            activity_type: "running",
            start: "2026-01-18T01:30:00.000Z",
            end: "2026-01-18T02:15:00.000Z",
            duration_s: 2700,
            source: "com.apple.health",
            device: "Watch7,1",
            synced_at: "2026-01-18T10:00:00.000Z",
            device_info: WorkoutFile.DeviceInfo(name: "Apple Watch", model: "Watch7,1", systemVersion: "11.0"),
            stats: ["distance": .init(value: 5000, unit: "m")],
            metadata: nil,
            route: [
                RoutePoint(t: "2026-01-18T01:30:05.123Z", lat: 31.234, lon: 121.456,
                           alt: 12.4, h_acc: 3.2, v_acc: 4.1, speed: 2.8,
                           speed_acc: 0.3, course: 273.5, course_acc: 5.0)
            ]
        )
        let json = try String(data: enc.encode(wf), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains(#""activity_type":"running""#))
        XCTAssertTrue(json.contains(#""duration_s":2700"#))
        XCTAssertTrue(json.contains(#""stats":{"distance":{"unit":"m","value":5000}}"#))
        XCTAssertTrue(json.contains(#""course":273.5"#))
    }

    func testWorkoutFileRouteNullForIndoor() throws {
        let wf = WorkoutFile(
            uuid: "A", activity_type: "yoga",
            start: "2026-01-18T01:30:00.000Z", end: "2026-01-18T02:00:00.000Z",
            duration_s: 1800, source: "com.apple.health",
            device: nil, synced_at: "2026-01-18T10:00:00.000Z",
            device_info: WorkoutFile.DeviceInfo(name: "iPhone", model: "iPhone16,2", systemVersion: "17.4"),
            stats: [:], metadata: nil, route: nil
        )
        let json = try String(data: enc.encode(wf), encoding: .utf8) ?? ""
        // route is explicitly null per spec, not omitted
        XCTAssertTrue(json.contains(#""route":null"#))
    }
}
