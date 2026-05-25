import XCTest
@testable import MyHealth

final class DayHashStoreTests: XCTestCase {
    private let dest: Destination = .myLifeDB

    override func setUp() {
        try? FileManager.default.removeItem(at: DayHashStore.url(for: dest))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: DayHashStore.url(for: dest))
    }

    func testLoadReturnsEmptyWhenFileMissing() {
        XCTAssertTrue(DayHashStore.load(for: dest).isEmpty)
    }

    func testSaveLoadRoundTrip() throws {
        let original: [String: String] = [
            "2026-05-19": "deadbeef",
            "2026-05-18": "cafebabe",
        ]
        try DayHashStore.save(original, for: dest)
        let loaded = DayHashStore.load(for: dest)
        XCTAssertEqual(loaded, original)
    }

    func testLoadReturnsEmptyOnCorruptJSON() throws {
        try "not valid json".data(using: .utf8)!.write(to: DayHashStore.url(for: dest), options: .atomic)
        XCTAssertTrue(DayHashStore.load(for: dest).isEmpty)
    }

    func testPerDestinationIsolation() throws {
        defer {
            try? FileManager.default.removeItem(at: DayHashStore.url(for: .myLifeDB))
            try? FileManager.default.removeItem(at: DayHashStore.url(for: .webdav))
        }
        try DayHashStore.save(["2026-05-19": "abc"], for: .myLifeDB)
        try DayHashStore.save(["2026-05-19": "xyz"], for: .webdav)
        XCTAssertEqual(DayHashStore.load(for: .myLifeDB)["2026-05-19"], "abc")
        XCTAssertEqual(DayHashStore.load(for: .webdav)["2026-05-19"], "xyz")
    }
}
