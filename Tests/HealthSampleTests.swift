import XCTest
import HealthKit
@testable import MyHealth

/// Verifies the new-format encoders for the per-day JSON layout.
/// (Legacy myhealth.apple_health.v1 row tests removed in this rewrite —
/// see docs/superpowers/plans/2026-05-19-day-based-incremental-sync.md
/// for rationale.)
final class HealthSampleTests: XCTestCase {

    func testISOTimestampHasZSuffixAndFractionalSeconds() {
        // 1768698000 → 2026-01-18T01:00:00 UTC (verified epoch from Task 3)
        let d = Date(timeIntervalSince1970: 1768698000)
        let s = SampleEncoder.iso(d)
        XCTAssertEqual(s, "2026-01-18T01:00:00.000Z")
    }

    func testStepCountCanonicalUnit() {
        let unit = SampleEncoder.canonicalUnit(
            for: HKQuantityType.quantityType(forIdentifier: .stepCount)!)
        XCTAssertEqual(unit.unitString, "count")
    }

    func testHeartRateUnitString() {
        let unit = SampleEncoder.canonicalUnit(
            for: HKQuantityType.quantityType(forIdentifier: .heartRate)!)
        XCTAssertEqual(unit.unitString, "count/min")
    }

    func testDeviceStringPrefersModel() {
        let model = SampleEncoder.deviceModelString(name: "Apple Watch",
                                                    model: "Watch7,1",
                                                    hardwareVersion: nil)
        XCTAssertEqual(model, "Watch7,1")
    }

    func testDeviceStringFallsBackToHardware() {
        let model = SampleEncoder.deviceModelString(name: nil, model: nil,
                                                    hardwareVersion: "Watch7,1")
        XCTAssertEqual(model, "Watch7,1")
    }

    func testDeviceStringNilWhenAllAbsent() {
        XCTAssertNil(SampleEncoder.deviceModelString(name: nil, model: nil, hardwareVersion: nil))
    }
}
