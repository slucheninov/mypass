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

    /// Кросс-совместимость: файл создан реальным KeePassXC (см. решение Task 1 —
    /// файл скопирован в Fixtures/ только если исход спайка — custom-parser).
    /// Пароль для фикстуры зафиксирован в `docs/superpowers/spikes/2026-07-21-keepasskit-vs-custom-parser.md`.
    func testOpensRealKeePassXCReferenceFile() throws {
        let fixtureURL = Bundle.module.url(forResource: "argon2id-aes256-gzip", withExtension: "kdbx", subdirectory: "Fixtures")
        guard let fixtureURL else {
            throw XCTSkip("Фикстура не найдена — скопировать из спайка Task 1 перед выполнением этого теста (см. Task 16)")
        }
        let data = try Data(contentsOf: fixtureURL)
        let database = try KdbxDatabase.open(data: data, password: "TestMasterPass123")
        XCTAssertFalse(database.rootGroup.name.isEmpty)
    }
}
