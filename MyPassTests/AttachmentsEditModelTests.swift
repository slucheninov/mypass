import XCTest
import MyPassKit
@testable import MyPass

final class AttachmentsEditModelTests: XCTestCase {
    private func urls(_ n: Int) -> [URL] { (0..<n).map { URL(fileURLWithPath: "/x/f\($0).txt") } }
    private let fakeRead: (URL) throws -> (name: String, data: Data) = { ($0.lastPathComponent, Data([1])) }

    func testAddingValidURLsAppendsAttachments() {
        var m = AttachmentsEditModel()
        m.add(urls: urls(2), read: fakeRead)
        XCTAssertEqual(m.attachments.map(\.name), ["f0.txt", "f1.txt"])
        XCTAssertTrue(m.attachments.allSatisfy(\.isProtected))
        XCTAssertNil(m.errorMessage)
    }

    func testDirectoryURLProducesErrorAndSkipsOnlyThatItem() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ok-\(UUID().uuidString).txt")
        try Data([9]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var m = AttachmentsEditModel()
        m.add(urls: [dir, file])
        XCTAssertEqual(m.attachments.count, 1)
        XCTAssertEqual(m.errorMessage, AttachmentAddError.notARegularFile(name: dir.lastPathComponent).errorDescription)
    }

    func testOverLimitDropKeepsFirstEightAndReportsError() {
        var m = AttachmentsEditModel()
        m.add(urls: urls(10), read: fakeRead)
        XCTAssertEqual(m.attachments.count, 8)
        XCTAssertEqual(m.attachments.last?.name, "f7.txt")
        XCTAssertEqual(m.errorMessage, AttachmentAddError.tooManyFiles.errorDescription)
    }

    func testAllRejectionsAreReportedTogether() {
        var m = AttachmentsEditModel()
        let read: (URL) throws -> (name: String, data: Data) = { url in
            if url.lastPathComponent == "f1.txt" { throw AttachmentAddError.fileTooLarge(name: "f1.txt") }
            if url.lastPathComponent == "f2.txt" { throw AttachmentAddError.unreadable(name: "f2.txt") }
            return (url.lastPathComponent, Data([1]))
        }
        m.add(urls: urls(4), read: read)
        XCTAssertEqual(m.attachments.map(\.name), ["f0.txt", "f3.txt"])
        let lines = m.errorMessage?.components(separatedBy: "\n")
        XCTAssertEqual(lines, [AttachmentAddError.fileTooLarge(name: "f1.txt").errorDescription!,
                               AttachmentAddError.unreadable(name: "f2.txt").errorDescription!])
    }

    func testRemoveAtIndex() {
        var m = AttachmentsEditModel()
        m.add(urls: urls(3), read: fakeRead)
        m.remove(at: 1)
        XCTAssertEqual(m.attachments.map(\.name), ["f0.txt", "f2.txt"])
        m.remove(at: 99)
        XCTAssertEqual(m.attachments.count, 2)
    }

    func testSavedEntryCarriesEditedAttachmentsAndKeepsProtectedFlags() {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let old = KdbxAttachment(name: "old.txt", data: Data([1]), isProtected: false)
        let entry = KdbxEntry(uuid: UUID(), iconID: 0, fields: [], attachments: [old],
                              creationTime: t, lastModificationTime: t, lastAccessTime: t,
                              locationChanged: t, history: [])
        var m = AttachmentsEditModel(attachments: entry.attachments)
        m.add(urls: urls(1), read: fakeRead)
        let saved = m.applying(to: entry)
        XCTAssertEqual(saved.attachments.map(\.name), ["old.txt", "f0.txt"])
        XCTAssertFalse(saved.attachments[0].isProtected)
        XCTAssertTrue(saved.attachments[1].isProtected)
        var removed = m
        removed.remove(at: 0)
        XCTAssertEqual(removed.applying(to: entry).attachments.map(\.name), ["f0.txt"])
    }

    func testDuplicateDroppedNamesGetSuffixes() {
        var m = AttachmentsEditModel()
        m.add(urls: [URL(fileURLWithPath: "/a/r.pdf"), URL(fileURLWithPath: "/b/r.pdf")], read: fakeRead)
        XCTAssertEqual(m.attachments.map(\.name), ["r.pdf", "r (2).pdf"])
    }

    func testDeleteConfirmationOnlyForAlreadyStoredFiles() {
        let stored = KdbxAttachment(name: "old.txt", data: Data([1]), isProtected: true)
        var model = AttachmentsEditModel(attachments: [stored])
        model.add(urls: [URL(fileURLWithPath: "/x/new.txt")], read: { _ in ("new.txt", Data([2])) })
        XCTAssertEqual(model.attachments.map(\.name), ["old.txt", "new.txt"])
        XCTAssertTrue(model.needsDeleteConfirmation(at: 0))
        XCTAssertFalse(model.needsDeleteConfirmation(at: 1))
        XCTAssertFalse(model.needsDeleteConfirmation(at: 5))
    }

    func testPendingDropLoadBlocksUntilFinishedOnSuccess() {
        var m = AttachmentsEditModel()
        XCTAssertFalse(m.isLoadingDrops)
        m.beginDropLoad()
        m.beginDropLoad()
        XCTAssertTrue(m.isLoadingDrops)
        m.finishDropLoad(urls: [URL(fileURLWithPath: "/x/a.txt")], read: fakeRead)
        XCTAssertEqual(m.pendingLoads, 1)
        XCTAssertTrue(m.isLoadingDrops)
        m.finishDropLoad(urls: [URL(fileURLWithPath: "/x/b.txt")], read: fakeRead)
        XCTAssertEqual(m.pendingLoads, 0)
        XCTAssertFalse(m.isLoadingDrops)
        XCTAssertEqual(m.attachments.map(\.name), ["a.txt", "b.txt"])
    }

    func testFailedProviderLoadStillClearsPendingAndReportsError() {
        var m = AttachmentsEditModel()
        m.beginDropLoad()
        m.finishDropLoad(urls: [nil, URL(fileURLWithPath: "/x/ok.txt")], read: fakeRead)
        XCTAssertEqual(m.pendingLoads, 0)
        XCTAssertFalse(m.isLoadingDrops)
        XCTAssertEqual(m.attachments.map(\.name), ["ok.txt"])
        XCTAssertEqual(m.errorMessage, AttachmentAddError.dropLoadFailed.errorDescription)
    }

    func testFinishWithoutBeginNeverGoesNegative() {
        var m = AttachmentsEditModel()
        m.finishDropLoad(urls: [], read: fakeRead)
        XCTAssertEqual(m.pendingLoads, 0)
    }

    func testErrorSurvivesLaterSuccessfulDrop() {
        var m = AttachmentsEditModel()
        m.beginDropLoad()
        m.beginDropLoad()
        m.finishDropLoad(urls: [nil], read: fakeRead)
        m.finishDropLoad(urls: [URL(fileURLWithPath: "/x/ok.txt")], read: fakeRead)
        XCTAssertEqual(m.attachments.map(\.name), ["ok.txt"])
        XCTAssertEqual(m.errorMessage, AttachmentAddError.dropLoadFailed.errorDescription)
    }

    func testTwoFailuresBothAppear() {
        var m = AttachmentsEditModel()
        m.add(urls: [], extraErrors: ["first"], read: fakeRead)
        m.add(urls: [], extraErrors: ["second"], read: fakeRead)
        XCTAssertEqual(m.errorMessage, "first\nsecond")
    }

    func testDismissClearsError() {
        var m = AttachmentsEditModel()
        m.add(urls: [], extraErrors: ["boom"], read: fakeRead)
        m.dismissError()
        XCTAssertNil(m.errorMessage)
    }
}
