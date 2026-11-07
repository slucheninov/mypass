import XCTest
@testable import MyPassKit

final class KdbxAttachmentPoolTests: XCTestCase {
    private let t = Date(timeIntervalSince1970: 0)

    private func entry(_ attachments: [KdbxAttachment], history: [KdbxEntry] = []) -> KdbxEntry {
        KdbxEntry(uuid: UUID(), iconID: 0, fields: [], attachments: attachments,
                  creationTime: t, lastModificationTime: t, lastAccessTime: t,
                  locationChanged: t, history: history)
    }

    private func group(entries: [KdbxEntry] = [], subgroups: [KdbxGroup] = []) -> KdbxGroup {
        KdbxGroup(uuid: UUID(), name: "g", iconID: 0, creationTime: t,
                  lastModificationTime: t, locationChanged: t,
                  entries: entries, subgroups: subgroups)
    }

    private func att(_ name: String, _ bytes: [UInt8], protected: Bool = true) -> KdbxAttachment {
        KdbxAttachment(name: name, data: Data(bytes), isProtected: protected)
    }

    func testIdenticalContentAndFlagIsStoredOnce() {
        let a = att("a.txt", [1, 2, 3])
        let b = att("b.txt", [1, 2, 3])
        let root = group(entries: [entry([a]), entry([b])])
        let pool = KdbxAttachmentPool(collecting: root)
        XCTAssertEqual(pool.binaries.count, 1)
        XCTAssertEqual(pool.index(of: a), pool.index(of: b))
    }

    func testSameContentDifferentProtectionIsStoredTwice() {
        let a = att("a.txt", [1, 2, 3], protected: true)
        let b = att("b.txt", [1, 2, 3], protected: false)
        let pool = KdbxAttachmentPool(collecting: group(entries: [entry([a, b])]))
        XCTAssertEqual(pool.binaries.count, 2)
        XCTAssertNotEqual(pool.index(of: a), pool.index(of: b))
        XCTAssertEqual(pool.binaries[pool.index(of: b)].isProtected, false)
    }

    func testHistoryOnlyAttachmentIsIncluded() {
        let h = att("old.txt", [9])
        let root = group(entries: [entry([], history: [entry([h])])])
        let pool = KdbxAttachmentPool(collecting: root)
        XCTAssertEqual(pool.binaries.count, 1)
        XCTAssertEqual(pool.index(of: h), 0)
    }

    func testOrderIsFirstUseInEncoderTraversal() {
        let sub = att("sub", [3])
        let own = att("own", [0])
        let hist = att("hist", [1])
        let second = att("second", [2])
        // Entry attachments first, then its history; entries before subgroups.
        let subgroup = group(entries: [entry([sub])])
        let root = group(entries: [entry([own], history: [entry([hist])]), entry([second])],
                         subgroups: [subgroup])
        let pool = KdbxAttachmentPool(collecting: root)
        XCTAssertEqual(pool.binaries.map(\.content), [Data([0]), Data([1]), Data([2]), Data([3])])
        XCTAssertEqual([own, hist, second, sub].map { pool.index(of: $0) }, [0, 1, 2, 3])
    }

    func testNoAttachmentsYieldsEmptyPool() {
        let pool = KdbxAttachmentPool(collecting: group(entries: [entry([])]))
        XCTAssertEqual(pool.binaries, [])
        XCTAssertEqual(pool, KdbxAttachmentPool.empty)
    }

    func testEmptyDataAttachmentIsKept() {
        let a = att("empty", [])
        let pool = KdbxAttachmentPool(collecting: group(entries: [entry([a])]))
        XCTAssertEqual(pool.binaries.count, 1)
        XCTAssertEqual(pool.binaries[0].content, Data())
    }
}
