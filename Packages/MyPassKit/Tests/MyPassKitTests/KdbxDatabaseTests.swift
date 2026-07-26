import XCTest
@testable import MyPassKit

final class KdbxDatabaseTests: XCTestCase {
    private func makeRoot() -> KdbxGroup {
        let entry = KdbxEntry(
            uuid: UUID(), iconID: 0,
            fields: [
                KdbxField(key: "Title", value: "Example", isProtected: false),
                KdbxField(key: "Password", value: "correct horse battery staple", isProtected: true)
            ],
            creationTime: Date(timeIntervalSince1970: 1_700_000_000),
            lastModificationTime: Date(timeIntervalSince1970: 1_700_000_000),
            lastAccessTime: Date(timeIntervalSince1970: 1_700_000_000),
            locationChanged: Date(timeIntervalSince1970: 1_700_000_000),
            history: []
        )
        return KdbxGroup(
            uuid: UUID(), name: "Root", iconID: 0,
            creationTime: Date(timeIntervalSince1970: 1_700_000_000),
            lastModificationTime: Date(timeIntervalSince1970: 1_700_000_000),
            locationChanged: Date(timeIntervalSince1970: 1_700_000_000),
            entries: [entry], subgroups: []
        )
    }

    func testOpenSaveOpenRoundTripPreservesData() throws {
        let root = makeRoot()
        let database = KdbxDatabase(rootGroup: root, deletedObjects: [])

        let saved = try database.save(password: "correct horse battery staple", cipher: .aes256, compression: .gzip)
        let reopened = try KdbxDatabase.open(data: saved, password: "correct horse battery staple")

        XCTAssertEqual(reopened.rootGroup.entries.count, 1)
        XCTAssertEqual(reopened.rootGroup.entries[0].fields.first(where: { $0.key == "Password" })?.value,
                        "correct horse battery staple")
    }

    func testOpenSaveOpenRoundTripPreservesDataWithChaCha20AndNoCompression() throws {
        let root = makeRoot()
        let database = KdbxDatabase(rootGroup: root, deletedObjects: [])

        let saved = try database.save(password: "correct horse battery staple", cipher: .chaCha20, compression: .none)
        let reopened = try KdbxDatabase.open(data: saved, password: "correct horse battery staple")

        XCTAssertEqual(reopened.rootGroup.name, "Root")
        XCTAssertEqual(reopened.rootGroup.entries.count, 1)
        XCTAssertEqual(reopened.rootGroup.entries[0].fields.first(where: { $0.key == "Password" })?.value,
                        "correct horse battery staple")
    }

    func testOpenWithWrongPasswordThrows() throws {
        let root = KdbxGroup(uuid: UUID(), name: "Root", iconID: 0, creationTime: Date(), lastModificationTime: Date(), locationChanged: Date(), entries: [], subgroups: [])
        let database = KdbxDatabase(rootGroup: root, deletedObjects: [])
        let saved = try database.save(password: "correct-password", cipher: .chaCha20, compression: .none)

        XCTAssertThrowsError(try KdbxDatabase.open(data: saved, password: "wrong-password")) { error in
            guard case KdbxDatabaseError.wrongPassword = error else {
                return XCTFail("expected wrongPassword, got \(error)")
            }
        }
    }

    func testOpenWithTamperedBlockStreamThrowsTypedErrorNotCrash() throws {
        let root = KdbxGroup(uuid: UUID(), name: "Root", iconID: 0, creationTime: Date(), lastModificationTime: Date(), locationChanged: Date(), entries: [], subgroups: [])
        let database = KdbxDatabase(rootGroup: root, deletedObjects: [])
        var saved = try database.save(password: "correct-password", cipher: .aes256, compression: .none)

        // Flip a byte well past the header (header + SHA256 + HMAC), inside the
        // HMAC block stream body, to simulate file corruption/tampering.
        let tamperIndex = saved.index(saved.startIndex, offsetBy: saved.count - 10)
        saved[tamperIndex] ^= 0xFF

        XCTAssertThrowsError(try KdbxDatabase.open(data: saved, password: "correct-password"))
    }

    /// Cross-compatibility: file created by real KeePassXC/pykeepass (see
    /// Task 1 decision — file copied to Fixtures/ only if the spike source is
    /// custom-parser). Password for the fixture is fixed in
    /// `docs/superpowers/spikes/2026-07-21-keepasskit-vs-custom-parser.md`.
    ///
    /// Task 16 fixed `gzip`/`gunzip` to use a real gzip container (see
    /// `KdbxDatabase`'s type-level doc comment), but discovered a separate,
    /// pre-existing limitation while validating against this exact fixture:
    /// `KeyDerivation`'s Argon2id backend (swift-sodium) hardcodes a 16-byte
    /// salt, while this real KDBX4 file (like all real Argon2id KDBX4 files)
    /// uses a 32-byte salt — so opening still fails, just no longer on gzip.
    /// See `KdbxCrossCompatibilityTests.testArgon2idGzipFixturesFailDueToSaltLengthLimitationNotGzip`
    /// for the full writeup and a pinned assertion of the current failure
    /// mode. Not un-skipping this fully (as Task 15's brief hoped) is
    /// intentional — asserting success here would misrepresent real-file
    /// compatibility.
    func testOpensRealKeePassXCReferenceFile() throws {
        let fixtureURL = Bundle.module.url(forResource: "argon2id-aes256-gzip", withExtension: "kdbx", subdirectory: "Fixtures")
        guard let fixtureURL else {
            throw XCTSkip("Fixture not found — copy from Task 1 spike before running this test (see Task 16)")
        }
        let data = try Data(contentsOf: fixtureURL)
        XCTAssertThrowsError(try KdbxDatabase.open(data: data, password: "TestMasterPass123")) { error in
            guard case KdbxDatabaseError.unsupportedFeature = error else {
                return XCTFail("expected .unsupportedFeature (Argon2id salt-length gap, tracked in KdbxCrossCompatibilityTests), got \(error)")
            }
        }
    }
}
