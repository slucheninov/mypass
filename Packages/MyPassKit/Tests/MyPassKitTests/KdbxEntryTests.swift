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

    private func makeEntry(attachments: [KdbxAttachment] = []) -> KdbxEntry {
        let t = Date(timeIntervalSince1970: 0)
        return KdbxEntry(
            uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            iconID: 0,
            fields: [],
            attachments: attachments,
            creationTime: t,
            lastModificationTime: t,
            lastAccessTime: t,
            locationChanged: t,
            history: []
        )
    }

    func testAttachmentsDefaultToEmpty() {
        let entry = KdbxEntry(
            uuid: UUID(),
            iconID: 0,
            fields: [],
            creationTime: Date(),
            lastModificationTime: Date(),
            lastAccessTime: Date(),
            locationChanged: Date(),
            history: []
        )
        XCTAssertEqual(entry.attachments, [])
    }

    func testAttachmentsParticipateInEquality() {
        let a = makeEntry()
        let b = makeEntry(attachments: [KdbxAttachment(name: "a.txt", data: Data([1]), isProtected: true)])
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(b, makeEntry(attachments: [KdbxAttachment(name: "a.txt", data: Data([1]), isProtected: true)]))
    }

    func testAttachmentDefaultsToProtected() {
        XCTAssertTrue(KdbxAttachment(name: "a.txt", data: Data()).isProtected)
    }
}
