import XCTest
@testable import MyHealth

final class TypeNamingTests: XCTestCase {

    func testStripsQuantityPrefix() {
        XCTAssertEqual(TypeNaming.filename(for: "HKQuantityTypeIdentifierStepCount"),
                       "step-count.json")
    }

    func testStripsCategoryPrefix() {
        XCTAssertEqual(TypeNaming.filename(for: "HKCategoryTypeIdentifierSleepAnalysis"),
                       "sleep-analysis.json")
    }

    func testMultipleCamelHumps() {
        XCTAssertEqual(TypeNaming.filename(for: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN"),
                       "heart-rate-variability-sdnn.json")
    }

    func testAcronymRunStaysLower() {
        XCTAssertEqual(TypeNaming.filename(for: "HKQuantityTypeIdentifierVO2Max"),
                       "vo2-max.json")
    }

    func testDietaryProducesReadableName() {
        XCTAssertEqual(TypeNaming.filename(for: "HKQuantityTypeIdentifierDietaryVitaminB12"),
                       "dietary-vitamin-b12.json")
    }

    func testUnknownPrefixIsKebabbed() {
        // Defensive: any unknown prefix still gets kebab-cased without error.
        XCTAssertEqual(TypeNaming.filename(for: "HKCorrelationTypeIdentifierBloodPressure"),
                       "blood-pressure.json")
    }

    func testWorkoutFilename() {
        XCTAssertEqual(TypeNaming.workoutFilename(uuid: "A1B2C3D4-0000-0000-0000-000000000001"),
                       "workout-A1B2C3D4-0000-0000-0000-000000000001.json")
    }
}
