import XCTest
@testable import MyHealth

final class SnapshotMergerTests: XCTestCase {

    func testMergeDedupsByUUID() {
        let existing = [
            QuantitySample(start: "2026-01-18T01:00:00.000Z", end: "2026-01-18T01:10:00.000Z",
                           value: 100, unit: "count", type: "HKQuantityTypeIdentifierStepCount",
                           source: "S1", device: nil, metadata: nil, uuid: "U1"),
            QuantitySample(start: "2026-01-18T02:00:00.000Z", end: "2026-01-18T02:10:00.000Z",
                           value: 50,  unit: "count", type: "HKQuantityTypeIdentifierStepCount",
                           source: "S1", device: nil, metadata: nil, uuid: "U2"),
        ]
        // Incoming includes a corrected U1 (value=150 instead of 100) plus a new U3.
        let incoming = [
            QuantitySample(start: "2026-01-18T01:00:00.000Z", end: "2026-01-18T01:10:00.000Z",
                           value: 150, unit: "count", type: "HKQuantityTypeIdentifierStepCount",
                           source: "S1", device: nil, metadata: nil, uuid: "U1"),
            QuantitySample(start: "2026-01-18T03:00:00.000Z", end: "2026-01-18T03:10:00.000Z",
                           value: 25,  unit: "count", type: "HKQuantityTypeIdentifierStepCount",
                           source: "S1", device: nil, metadata: nil, uuid: "U3"),
        ]
        let merged = SnapshotMerger.merge(existing: existing, incoming: incoming)
        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged.first(where: { $0.uuid == "U1" })?.value, 150) // new wins
    }

    func testMergeSortsByStartEndSource() {
        let a = QuantitySample(start: "2026-01-18T02:00:00.000Z", end: "2026-01-18T02:01:00.000Z",
                               value: 1, unit: "count", type: "T",
                               source: "B", device: nil, metadata: nil, uuid: "A")
        let b = QuantitySample(start: "2026-01-18T01:00:00.000Z", end: "2026-01-18T01:01:00.000Z",
                               value: 1, unit: "count", type: "T",
                               source: "A", device: nil, metadata: nil, uuid: "B")
        let c = QuantitySample(start: "2026-01-18T01:00:00.000Z", end: "2026-01-18T01:02:00.000Z",
                               value: 1, unit: "count", type: "T",
                               source: "A", device: nil, metadata: nil, uuid: "C")
        let d = QuantitySample(start: "2026-01-18T01:00:00.000Z", end: "2026-01-18T01:01:00.000Z",
                               value: 1, unit: "count", type: "T",
                               source: "B", device: nil, metadata: nil, uuid: "D")
        let merged = SnapshotMerger.merge(existing: [a], incoming: [b, c, d])
        XCTAssertEqual(merged.map(\.uuid), ["B", "D", "C", "A"])
    }

    func testMergeEmptyExisting() {
        let s = QuantitySample(start: "2026-01-18T01:00:00.000Z", end: "2026-01-18T01:10:00.000Z",
                               value: 1, unit: "count", type: "T",
                               source: "S", device: nil, metadata: nil, uuid: "U1")
        XCTAssertEqual(SnapshotMerger.merge(existing: [], incoming: [s]).count, 1)
    }

    func testMergeCategorySamples() {
        let a = CategorySample(start: "2026-01-18T22:00:00.000Z", end: "2026-01-18T22:30:00.000Z",
                               value: "awake", type: "HKCategoryTypeIdentifierSleepAnalysis",
                               source: "S", device: nil, metadata: nil, uuid: "U1")
        let b = CategorySample(start: "2026-01-18T20:00:00.000Z", end: "2026-01-18T21:00:00.000Z",
                               value: "asleepCore", type: "HKCategoryTypeIdentifierSleepAnalysis",
                               source: "S", device: nil, metadata: nil, uuid: "U2")
        let merged = SnapshotMerger.mergeCategory(existing: [a], incoming: [b])
        XCTAssertEqual(merged.map(\.uuid), ["U2", "U1"])
    }
}
