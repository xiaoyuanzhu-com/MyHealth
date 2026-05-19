import XCTest
@testable import MyHealth

final class DayHashStoreTests: XCTestCase {

    private var tmpURL: URL!

    override func setUp() {
        tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("day-hashes-\(UUID()).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpURL)
    }

    func testLoadReturnsEmptyWhenFileMissing() {
        XCTAssertTrue(DayHashStore.load(at: tmpURL).isEmpty)
    }

    func testSaveLoadRoundTrip() throws {
        let original: [String: String] = [
            "2026-05-19": "deadbeef",
            "2026-05-18": "cafebabe",
        ]
        try DayHashStore.save(original, at: tmpURL)
        let loaded = DayHashStore.load(at: tmpURL)
        XCTAssertEqual(loaded, original)
    }

    func testLoadReturnsEmptyOnCorruptJSON() throws {
        try "not valid json".data(using: .utf8)!.write(to: tmpURL, options: .atomic)
        XCTAssertTrue(DayHashStore.load(at: tmpURL).isEmpty)
    }
}
