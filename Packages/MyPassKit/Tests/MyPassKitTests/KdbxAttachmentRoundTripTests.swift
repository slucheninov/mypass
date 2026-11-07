import XCTest
@testable import MyPassKit

// Fixture provenance: `Fixtures/keepassxc-attachments.kdbx` is NOT checked in yet.
// It must come from a real KeePassXC (never hand-faked): `keepassxc-cli db-create`
// (password `fixture-password`), `add` an entry, `attachment-import` a 3-byte text
// file and a 70 KB random binary, `edit -t` the entry so the previous version (with
// both attachments) lands in history, then `attachment-import` a third file.
// `keepassxc-cli` was not available when this task was implemented, so
// `testKeePassXCFixtureWithAttachmentsRoundTrips` skips until the file is produced.
// pykeepass is not installed in the development environment either, and the existing
// `PykeepassBidirectionalTests` expects a system-wide install, so no pykeepass fixture
// exists.

final class KdbxAttachmentRoundTripTests: XCTestCase {
    private let password = "correct horse battery staple"
    private let t = Date(timeIntervalSince1970: 1_700_000_000)

    private func entry(_ title: String, attachments: [KdbxAttachment], history: [KdbxEntry] = []) -> KdbxEntry {
        KdbxEntry(
            uuid: UUID(), iconID: 0,
            fields: [KdbxField(key: "Title", value: title, isProtected: false)],
            attachments: attachments,
            creationTime: t, lastModificationTime: t, lastAccessTime: t, locationChanged: t,
            history: history
        )
    }

    private func database(_ entries: [KdbxEntry]) -> KdbxDatabase {
        let root = KdbxGroup(uuid: UUID(), name: "Root", iconID: 0, creationTime: t,
                             lastModificationTime: t, locationChanged: t,
                             entries: entries, subgroups: [])
        return KdbxDatabase(rootGroup: root, deletedObjects: [])
    }

    private func roundTrip(_ db: KdbxDatabase, cipher: KdbxCipher = .aes256,
                           compression: KdbxCompression = .gzip) throws -> KdbxDatabase {
        try KdbxDatabase.open(data: db.save(password: password, cipher: cipher, compression: compression), password: password)
    }

    func testOpenSaveOpenPreservesAttachmentsAndFlags() throws {
        for (cipher, compression) in [(KdbxCipher.aes256, KdbxCompression.gzip), (.chaCha20, .none)] {
            let e = entry("A", attachments: [
                KdbxAttachment(name: "secret.bin", data: Data([1, 2, 3, 4]), isProtected: true),
                KdbxAttachment(name: "note.txt", data: Data("hi!".utf8), isProtected: false),
            ])
            let db = database([e])
            let reopened = try roundTrip(db, cipher: cipher, compression: compression)
            XCTAssertEqual(reopened, db)
            XCTAssertEqual(reopened.rootGroup.entries[0].attachments, e.attachments)
            // Saving again must stay stable.
            XCTAssertEqual(try roundTrip(reopened, cipher: cipher, compression: compression), db)
        }
    }

    func testHistoryOnlyAttachmentSurvivesRoundTrip() throws {
        let old = entry("Old", attachments: [KdbxAttachment(name: "old.bin", data: Data([9, 8, 7]), isProtected: true)])
        let current = entry("New", attachments: [], history: [old])
        let db = database([current])
        let reopened = try roundTrip(db)
        XCTAssertEqual(reopened, db)
        XCTAssertEqual(reopened.rootGroup.entries[0].history[0].attachments, old.attachments)
    }

    func testIdenticalAttachmentsAcrossEntriesRoundTripAsSeparateEqualValues() throws {
        let a = KdbxAttachment(name: "a.txt", data: Data([1, 2, 3]), isProtected: true)
        let b = KdbxAttachment(name: "b.txt", data: Data([1, 2, 3]), isProtected: true)
        let db = database([entry("One", attachments: [a]), entry("Two", attachments: [b])])
        let reopened = try roundTrip(db)
        XCTAssertEqual(reopened, db)
        XCTAssertEqual(reopened.rootGroup.entries[0].attachments, [a])
        XCTAssertEqual(reopened.rootGroup.entries[1].attachments, [b])
    }

    func testVaultWithoutAttachmentsStillRoundTrips() throws {
        let db = database([entry("Plain", attachments: [])])
        let reopened = try roundTrip(db)
        XCTAssertEqual(reopened, db)
        XCTAssertTrue(reopened.rootGroup.entries[0].attachments.isEmpty)
    }

    /// The engine must round-trip vaults beyond the UI limits (8 files, 5 MB) untouched.
    func testOverLimitVaultRoundTripsUntouched() throws {
        let many = (0..<20).map {
            KdbxAttachment(name: "file\($0).bin", data: Data(repeating: UInt8($0), count: 10 + $0), isProtected: $0 % 2 == 0)
        }
        let db = database([entry("Many", attachments: many)])
        let reopened = try roundTrip(db)
        XCTAssertEqual(reopened, db)
        XCTAssertEqual(reopened.rootGroup.entries[0].attachments.count, 20)
    }

    func testFiftyMegabyteAttachmentRoundTripsUntouched() throws {
        let big = KdbxAttachment(name: "big.bin", data: Data(repeating: 0xAB, count: 50 * 1024 * 1024), isProtected: false)
        let db = database([entry("Big", attachments: [big])])
        let reopened = try roundTrip(db)
        XCTAssertEqual(reopened.rootGroup.entries[0].attachments.count, 1)
        XCTAssertTrue(reopened.rootGroup.entries[0].attachments[0] == big)
    }

    func testBinaryDataWithAllByteValuesRoundTrips() throws {
        let ramp = Data((0...255).map { UInt8($0) })
        let db = database([entry("Ramp", attachments: [KdbxAttachment(name: "ramp.bin", data: ramp, isProtected: true)])])
        let reopened = try roundTrip(db)
        XCTAssertEqual(reopened.rootGroup.entries[0].attachments[0].data, ramp)
        XCTAssertEqual(reopened, db)
    }

    func testKeePassXCFixtureWithAttachmentsRoundTrips() throws {
        guard let url = Bundle.module.url(forResource: "keepassxc-attachments", withExtension: "kdbx", subdirectory: "Fixtures") else {
            throw XCTSkip("fixture not produced")
        }
        let opened = try KdbxDatabase.open(data: Data(contentsOf: url), password: "fixture-password")
        let all = opened.rootGroup.entries
        XCTAssertFalse(all.isEmpty)
        XCTAssertTrue(all.contains { !$0.attachments.isEmpty }, "fixture must carry attachments")
        XCTAssertTrue(all.contains { $0.history.contains { !$0.attachments.isEmpty } }, "a history version must carry an attachment")
        XCTAssertTrue(all.flatMap(\.attachments).contains { $0.data.count == 70 * 1024 || $0.data.count == 3 })
        XCTAssertEqual(try roundTrip(opened), opened)
    }
}
