import XCTest
@testable import MyPassKit

final class KdbxEntryTests: XCTestCase {
    func testStringArraysDefaultsToEmptyAndIsSettable() {
        var entry = KdbxEntry(
            uuid: UUID(),
            iconID: 0,
            fields: [],
            creationTime: Date(),
            lastModificationTime: Date(),
            lastAccessTime: Date(),
            locationChanged: Date(),
            history: []
        )
        XCTAssertEqual(entry.stringArrays, [])

        entry.stringArrays = [KdbxStringArray(key: "KP2A_URL", values: ["https://a.example.com", "https://b.example.com"])]
        XCTAssertEqual(entry.stringArrays.first?.key, "KP2A_URL")
        XCTAssertEqual(entry.stringArrays.first?.values, ["https://a.example.com", "https://b.example.com"])
    }

    func testKdbxStringArrayEquatable() {
        let a = KdbxStringArray(key: "KP2A_URL", values: ["https://a.example.com"])
        let b = KdbxStringArray(key: "KP2A_URL", values: ["https://a.example.com"])
        let c = KdbxStringArray(key: "KP2A_URL", values: ["https://c.example.com"])
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
