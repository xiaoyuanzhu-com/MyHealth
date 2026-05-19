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
        let dayKey = DayBucketer.DayKey(date: "2026-01-18", timezone: "Asia/Shanghai")
        let qSample = QuantitySample(
            start: "2026-01-18T01:00:00.000Z", end: "2026-01-18T01:10:00.000Z",
            value: 200, unit: "count", type: "HKQuantityTypeIdentifierStepCount",
            source: "S", device: nil, metadata: nil, uuid: "U1"
        )
        let bucket = SyncRunState.DayBucket(
            key: dayKey,
            quantitySamples: ["HKQuantityTypeIdentifierStepCount": [qSample]],
            categorySamples: [:],
            workouts: []
        )
        let state = SyncRunState(
            runID: "20260518T120000Z",
            startedAt: "2026-05-18T12:00:00Z",
            anchorsAtStart: ["HKQuantityTypeIdentifierStepCount": "anchor-base64"],
            newAnchors: ["HKQuantityTypeIdentifierStepCount": "anchor-base64-new"],
            buckets: [bucket],
            completedDayCount: 0
        )

        try SyncRunStore.save(state, at: tmpURL)
        let loaded = try XCTUnwrap(SyncRunStore.load(at: tmpURL))
        XCTAssertEqual(loaded, state)
    }

    func testLoadMissingReturnsNil() throws {
        XCTAssertNil(SyncRunStore.load(at: tmpURL))
    }

    func testClearRemovesFile() throws {
        let state = SyncRunState(
            runID: "x", startedAt: "y", anchorsAtStart: [:], newAnchors: [:],
            buckets: [], completedDayCount: 0
        )
        try SyncRunStore.save(state, at: tmpURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpURL.path))
        SyncRunStore.clear(at: tmpURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpURL.path))
    }

    func testRemainingDaysSkipsCompleted() {
        let b1 = SyncRunState.DayBucket(
            key: .init(date: "2026-01-18", timezone: "Asia/Shanghai"),
            quantitySamples: [:], categorySamples: [:], workouts: [])
        let b2 = SyncRunState.DayBucket(
            key: .init(date: "2026-01-19", timezone: "Asia/Shanghai"),
            quantitySamples: [:], categorySamples: [:], workouts: [])
        let state = SyncRunState(
            runID: "x", startedAt: "y", anchorsAtStart: [:], newAnchors: [:],
            buckets: [b1, b2], completedDayCount: 1
        )
        XCTAssertEqual(state.remainingDays.map(\.key.date), ["2026-01-19"])
    }
}
