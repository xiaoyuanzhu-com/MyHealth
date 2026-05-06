import XCTest
@testable import MyHealth

final class ManifestTests: XCTestCase {

    func testManifestRoundTrip() throws {
        let manifest = SyncManifest(
            schema: SyncManifest.schemaID,
            device_id: "device-123",
            device_model: "iPhone15,2",
            os_version: "iOS 17.4",
            app_version: "0.1.0",
            batches: [
                .init(
                    batch_id: "20260506T112233Z",
                    started_at: "2026-05-06T11:22:33Z",
                    finished_at: "2026-05-06T11:22:55Z",
                    counts: ["records": 1234, "workouts": 2],
                    files: [
                        .init(name: "records.jsonl", size: 65536, sha256: "abc")
                    ]
                )
            ],
            anchors: ["HKQuantityTypeIdentifierStepCount": "fakeBase64Anchor=="],
            updated_at: "2026-05-06T11:22:55Z"
        )

        let data = try JSONEncoder.deterministic.encode(manifest)
        let decoded = try JSONDecoder().decode(SyncManifest.self, from: data)

        XCTAssertEqual(decoded, manifest)
    }

    func testSchemaIDIsStable() {
        XCTAssertEqual(SyncManifest.schemaID, "myhealth.healthkit.v1")
    }

    func testManifestMergeAddsNewBatch() {
        // Simulates the SyncCoordinator flow: an existing manifest is loaded,
        // a new batch is appended, anchors are merged.
        var existing = SyncManifest(
            device_id: "d", device_model: "m", os_version: "o", app_version: "a",
            batches: [.init(batch_id: "A", started_at: "x", finished_at: "y",
                            counts: ["records": 10], files: [])],
            anchors: ["t1": "v1"],
            updated_at: "y"
        )
        existing.anchors["t1"] = "v1-newer"
        existing.batches.append(.init(batch_id: "B", started_at: "x2", finished_at: "y2",
                                      counts: ["records": 5], files: []))
        XCTAssertEqual(existing.batches.count, 2)
        XCTAssertEqual(existing.anchors["t1"], "v1-newer")
    }
}
