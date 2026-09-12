import CryptoKit
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

    /// Cross-compatibility: a real pykeepass-generated file, regenerated with
    /// realistic parameters in Task 6 of
    /// docs/superpowers/plans/2026-09-12-kdbx4-argon2-interop.md. Renamed from
    /// `testOpensRealKeePassXCReferenceFile` now that it actually opens —
    /// asserting failure here would misrepresent what this package can do.
    func testOpensRealKeePassXCArgon2idReferenceFile() throws {
        guard let fixtureURL = Bundle.module.url(forResource: "argon2id-aes256-gzip", withExtension: "kdbx", subdirectory: "Fixtures") else {
            throw XCTSkip("Fixture not found — see Task 6 of docs/superpowers/plans/2026-09-12-kdbx4-argon2-interop.md")
        }
        let data = try Data(contentsOf: fixtureURL)
        let database = try KdbxDatabase.open(data: data, password: "TestMasterPass123")
        XCTAssertEqual(database.rootGroup.entries.count, 1)
        XCTAssertEqual(database.rootGroup.entries.first?.fields.first(where: { $0.key == "Title" })?.value, "Test Entry")
    }

    /// `save()` must write a 32-byte Argon2 salt and parallelism 2 — the shape
    /// every real KDBX4 file uses, per Decision 4 of
    /// docs/superpowers/specs/2026-09-12-kdbx4-argon2-interop-design.md. Parses
    /// the actual written header (not just round-tripping through `open`) so a
    /// regression that happens to still open correctly can't hide behind a
    /// passing round trip.
    func testSaveWritesStrongerKdfParametersThanBefore() throws {
        let root = KdbxGroup(uuid: UUID(), name: "Root", iconID: 0, creationTime: Date(), lastModificationTime: Date(), locationChanged: Date(), entries: [], subgroups: [])
        let database = KdbxDatabase(rootGroup: root, deletedObjects: [])
        let saved = try database.save(password: "correct horse battery staple", cipher: .aes256, compression: .gzip)

        var offset = saved.index(saved.startIndex, offsetBy: 12)
        let outerHeader = try KdbxOuterHeader.parse(from: saved, startingAt: &offset, rawHeaderStart: saved.startIndex)

        guard case .byteArray(let salt)? = outerHeader.kdfParameters.items["S"] else {
            return XCTFail("missing S")
        }
        guard case .uint32(let parallelism)? = outerHeader.kdfParameters.items["P"] else {
            return XCTFail("missing P")
        }
        XCTAssertEqual(salt.count, 32, "save() must write a 32-byte Argon2 salt, matching real KDBX4 files")
        XCTAssertEqual(parallelism, 2)

        let reopened = try KdbxDatabase.open(data: saved, password: "correct horse battery staple")
        XCTAssertEqual(reopened.rootGroup.name, "Root")
    }

    /// Backward compatibility: a vault written with the OLD parameters (16-byte
    /// salt, P=1 — what `save()` wrote before this task) must still open after
    /// `save()` itself moves on to stronger parameters. Reproduces the old
    /// `save()` shape directly against this package's own internal building
    /// blocks (`VariantDictionary`, `KdbxOuterHeader`, `KeyDerivation`,
    /// `HmacBlockStream`, the outer ciphers, `KdbxInnerHeader`,
    /// `InnerRandomStreamCipher`, `KdbxXmlCoder`) rather than a vendored binary
    /// fixture, so the "old shape" this test pins is readable and diffable
    /// here rather than opaque bytes nobody can inspect.
    func testVaultWithOldSixteenByteSaltParametersStillOpens() throws {
        let masterSeed = Data(repeating: 0x11, count: 32)
        let salt = Data(repeating: 0x22, count: 16) // the OLD 16-byte salt shape
        var kdfParameters = VariantDictionary()
        kdfParameters.items["$UUID"] = .byteArray(KdbxKdfUUID.argon2id)
        kdfParameters.items["S"] = .byteArray(salt)
        kdfParameters.items["M"] = .uint64(64 * 1024 * 1024)
        kdfParameters.items["I"] = .uint64(3)
        kdfParameters.items["P"] = .uint32(1) // the OLD parallelism
        kdfParameters.items["V"] = .uint32(0x13)

        let cipher: KdbxCipher = .aes256
        let compression: KdbxCompression = .gzip
        let encryptionIV = Data(repeating: 0x33, count: 16)
        let outerHeader = KdbxOuterHeader(
            cipher: cipher, compression: compression,
            masterSeed: masterSeed, encryptionIV: encryptionIV,
            kdfParameters: kdfParameters, publicCustomData: nil, rawHeaderBytes: Data()
        )

        let password = "correct horse battery staple"
        let passwordHash = Data(SHA256.hash(data: Data(password.utf8)))
        let compositeKey = Data(SHA256.hash(data: passwordHash))
        let transformedKey = try KeyDerivation.transformedKey(compositeKey: compositeKey, kdfParameters: kdfParameters)
        let masterKey = KeyDerivation.masterKey(masterSeed: masterSeed, transformedKey: transformedKey)
        let hmacKeyBase = KeyDerivation.hmacKeyBase(masterSeed: masterSeed, transformedKey: transformedKey)

        let innerStreamKey = Data(repeating: 0x44, count: 64)
        let innerHeader = KdbxInnerHeader(innerRandomStreamID: .chaCha20, innerRandomStreamKey: innerStreamKey, binaries: [])
        let streamCipher = try InnerRandomStreamCipher(streamID: .chaCha20, rawKey: innerStreamKey)

        let root = KdbxGroup(uuid: UUID(), name: "LegacyRoot", iconID: 0, creationTime: Date(), lastModificationTime: Date(), locationChanged: Date(), entries: [], subgroups: [])
        let payload = KdbxXmlPayload(rootGroup: root, deletedObjects: [], recycleBinGroupUUID: nil)
        let xmlData = KdbxXmlCoder.encode(payload) { plaintext in
            let keystream = streamCipher.nextBytes(plaintext.count)
            return Data(zip(plaintext, keystream).map { $0 ^ $1 })
        }

        var innerPlaintext = innerHeader.serialize()
        innerPlaintext.append(xmlData)
        let compressed = try KdbxDatabase.gzip(innerPlaintext)
        let cipherText = try AES256CBCCipher.encrypt(plaintext: compressed, key: masterKey, iv: encryptionIV)
        let blockStream = HmacBlockStream.write(cipherText, hmacKeyBase: hmacKeyBase)

        var signatureAndVersion = Data()
        signatureAndVersion.append(contentsOf: withUnsafeBytes(of: UInt32(0x9AA2D903).littleEndian) { Data($0) })
        signatureAndVersion.append(contentsOf: withUnsafeBytes(of: UInt32(0xB54BFB67).littleEndian) { Data($0) })
        signatureAndVersion.append(contentsOf: withUnsafeBytes(of: UInt16(0x0000).littleEndian) { Data($0) })
        signatureAndVersion.append(contentsOf: withUnsafeBytes(of: UInt16(0x0004).littleEndian) { Data($0) })

        let headerFieldBytes = outerHeader.serialize()
        var rawHeaderBytes = signatureAndVersion
        rawHeaderBytes.append(headerFieldBytes)

        var legacyVault = signatureAndVersion
        legacyVault.append(headerFieldBytes)
        legacyVault.append(KdbxHeaderAuthentication.sha256(ofHeader: rawHeaderBytes))
        legacyVault.append(KdbxHeaderAuthentication.hmacSHA256(ofHeader: rawHeaderBytes, hmacKeyBase: hmacKeyBase))
        legacyVault.append(blockStream)

        let reopened = try KdbxDatabase.open(data: legacyVault, password: password)
        XCTAssertEqual(reopened.rootGroup.name, "LegacyRoot")
    }
}
