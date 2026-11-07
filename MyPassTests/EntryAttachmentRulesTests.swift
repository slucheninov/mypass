import XCTest
import MyPassKit
@testable import MyPass

final class EntryAttachmentRulesTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let t1 = Date(timeIntervalSince1970: 1_800_000_000)
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("att-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func entry(attachments: [KdbxAttachment] = []) -> KdbxEntry {
        KdbxEntry(uuid: UUID(), iconID: 0, fields: [], attachments: attachments,
                  creationTime: t0, lastModificationTime: t0, lastAccessTime: t0,
                  locationChanged: t0, history: [])
    }

    private func many(_ n: Int) -> [KdbxAttachment] {
        (0..<n).map { KdbxAttachment(name: "f\($0).txt", data: Data([1])) }
    }

    func testExactlyFiveMiBIsAccepted() throws {
        let e = try entry().addingAttachment(name: "a.bin", data: Data(count: 5 * 1024 * 1024))
        XCTAssertEqual(e.attachments.count, 1)
    }

    func testFiveMiBPlusOneIsRejected() {
        XCTAssertThrowsError(try entry().addingAttachment(name: "a.bin", data: Data(count: 5 * 1024 * 1024 + 1))) {
            XCTAssertEqual($0 as? AttachmentAddError, .fileTooLarge(name: "a.bin"))
        }
    }

    func testZeroByteFileIsAccepted() throws {
        let e = try entry().addingAttachment(name: "empty", data: Data())
        XCTAssertEqual(e.attachments.first?.data.count, 0)
    }

    func testNinthFileIsRejected() throws {
        var e = entry()
        for i in 0..<8 { e = try e.addingAttachment(name: "f\(i)", data: Data([1])) }
        XCTAssertEqual(e.attachments.count, 8)
        XCTAssertThrowsError(try e.addingAttachment(name: "f9", data: Data([1]))) {
            XCTAssertEqual($0 as? AttachmentAddError, .tooManyFiles)
        }
    }

    func testExistingOverLimitEntryKeepsAllAndRejectsOnlyNewAdds() {
        var e = entry(attachments: many(20))
        XCTAssertEqual(e.removingAttachment(at: 0).attachments.count, 19)
        e.fields.append(KdbxField(key: "Title", value: "x", isProtected: false))
        XCTAssertEqual(e.attachments.count, 20)
        XCTAssertThrowsError(try e.addingAttachment(name: "n", data: Data())) {
            XCTAssertEqual($0 as? AttachmentAddError, .tooManyFiles)
        }
    }

    func testDuplicateNameIsSuffixed() throws {
        var e = try entry().addingAttachment(name: "a.txt", data: Data([1]))
        e = try e.addingAttachment(name: "a.txt", data: Data([2]))
        e = try e.addingAttachment(name: "a.txt", data: Data([3]))
        XCTAssertEqual(e.attachments.map(\.name), ["a.txt", "a (2).txt", "a (3).txt"])
        var n = try entry().addingAttachment(name: "a", data: Data())
        n = try n.addingAttachment(name: "a", data: Data())
        XCTAssertEqual(n.attachments.map(\.name), ["a", "a (2)"])
    }

    func testPathSeparatorsAreStripped() {
        let s = AttachmentFileName.sanitized("../x/evil.txt")
        XCTAssertFalse(s.contains("/"))
        XCTAssertEqual(s, "evil.txt")
        XCTAssertFalse(AttachmentFileName.sanitized("a:b").contains(":"))
        XCTAssertFalse(AttachmentFileName.sanitized("a\u{0}b").contains("\u{0}"))
    }

    func testEmptyNameFallsBackToAttachment() {
        XCTAssertEqual(AttachmentFileName.sanitized("   "), "attachment")
        XCTAssertEqual(AttachmentFileName.sanitized("/"), "attachment")
        XCTAssertEqual(AttachmentFileName.sanitized(".."), "attachment")
    }

    func testNewAttachmentIsProtected() throws {
        let e = try entry().addingAttachment(name: "a", data: Data([1]))
        XCTAssertEqual(e.attachments.first?.isProtected, true)
    }

    func testMutationsBumpModificationTime() throws {
        let added = try entry().addingAttachment(name: "a", data: Data([1]), now: t1)
        XCTAssertEqual(added.lastModificationTime, t1)
        XCTAssertEqual(added.removingAttachment(at: 0, now: t1.addingTimeInterval(5)).lastModificationTime, t1.addingTimeInterval(5))
    }

    func testRemovingOutOfRangeIndexIsNoOp() {
        let e = entry(attachments: many(2))
        XCTAssertEqual(e.removingAttachment(at: 2, now: t1), e)
        XCTAssertEqual(e.removingAttachment(at: -1, now: t1), e)
        XCTAssertEqual(e.removingAttachment(at: 2, now: t1).lastModificationTime, t0)
    }

    func testReadFileRejectsDirectory() {
        XCTAssertThrowsError(try EntryAttachmentRules.readFile(at: tmp)) {
            XCTAssertEqual($0 as? AttachmentAddError, .notARegularFile(name: tmp.lastPathComponent))
        }
    }

    func testReadFileRejectsOversizeWithoutReadingIt() throws {
        let url = tmp.appendingPathComponent("big.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let h = try FileHandle(forWritingTo: url)
        try h.truncate(atOffset: UInt64(5 * 1024 * 1024 + 1))
        try h.close()
        XCTAssertThrowsError(try EntryAttachmentRules.readFile(at: url)) {
            XCTAssertEqual($0 as? AttachmentAddError, .fileTooLarge(name: "big.bin"))
        }
    }

    func testReadFileReturnsNameAndBytes() throws {
        let url = tmp.appendingPathComponent("note.txt")
        try Data("hello".utf8).write(to: url)
        let r = try EntryAttachmentRules.readFile(at: url)
        XCTAssertEqual(r.name, "note.txt")
        XCTAssertEqual(r.data, Data("hello".utf8))
    }

    func testReadFileMissingIsUnreadable() {
        let url = tmp.appendingPathComponent("nope")
        XCTAssertThrowsError(try EntryAttachmentRules.readFile(at: url)) {
            XCTAssertEqual($0 as? AttachmentAddError, .unreadable(name: "nope"))
        }
    }

    func testReadFileFollowsSymlinkToRegularFile() throws {
        let target = tmp.appendingPathComponent("real.txt")
        try Data([1, 2, 3]).write(to: target)
        let link = tmp.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let result = try EntryAttachmentRules.readFile(at: link)
        XCTAssertEqual(result.name, "link.txt")
        XCTAssertEqual(result.data, Data([1, 2, 3]))
    }

    func testReadFileRejectsSymlinkToDirectory() throws {
        let dir = tmp.appendingPathComponent("d")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        let link = tmp.appendingPathComponent("dlink")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir)
        XCTAssertThrowsError(try EntryAttachmentRules.readFile(at: link)) {
            XCTAssertEqual($0 as? AttachmentAddError, .notARegularFile(name: "dlink"))
        }
    }

    func testBoundedReadStopsAfterLimitPlusOne() throws {
        // Simulates a file that grew after the metadata check: the read must reject
        // it, and must not have consumed more than limit + 1 bytes.
        let file = tmp.appendingPathComponent("grown.bin")
        try Data(count: EntryAttachmentRules.maxBytesPerFile + 10).write(to: file)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        XCTAssertThrowsError(try EntryAttachmentRules.boundedRead(from: handle, name: "grown.bin")) {
            XCTAssertEqual($0 as? AttachmentAddError, .fileTooLarge(name: "grown.bin"))
        }
        XCTAssertEqual(try handle.offset(), UInt64(EntryAttachmentRules.maxBytesPerFile + 1))
    }

    func testBoundedReadAcceptsExactlyTheLimit() throws {
        let file = tmp.appendingPathComponent("max.bin")
        try Data(count: EntryAttachmentRules.maxBytesPerFile).write(to: file)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        XCTAssertEqual(try EntryAttachmentRules.boundedRead(from: handle, name: "max.bin").count,
                       EntryAttachmentRules.maxBytesPerFile)
    }

    func testSanitizedStripsControlCharacters() {
        XCTAssertEqual(AttachmentFileName.sanitized("a\u{1}b\tc\nd\u{1F}e\u{7F}f.txt"), "abcdef.txt")
        XCTAssertEqual(AttachmentFileName.sanitized("\u{7}\u{8}"), AttachmentFileName.fallback)
    }
}
