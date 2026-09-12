import XCTest
import Sodium
@testable import MyPassKit

final class KeyDerivationTests: XCTestCase {
    /// Cross-check of the swift-sodium/libsodium wrapper itself: the test vector
    /// comes from libsodium's test suite (test/default/pwhash_argon2id.c, tv3()),
    /// NOT from the "raw" Argon2 reference vectors (phc-winner-argon2/kats), because
    /// libsodium's crypto_pwhash API does not support optional secret/associatedData
    /// parameters of "raw" Argon2 (which is fine — KDBX4 does not use them either, see
    /// Global Constraints). We verify via the encoded string, because that is exactly what
    /// is fixed in the libsodium test source.
    ///
    /// NOTE: tv3()'s test index 0 (m=4096,t=0,p=1) is intentionally an edge case in
    /// libsodium's own test — the C test only *prints* a warning on failure there
    /// ("maybe intentional"), rather than asserting success, because t=0 is below
    /// `crypto_pwhash_argon2id_OPSLIMIT_MIN` (1) and libsodium's own str_verify
    /// rejects it. Confirmed empirically: `strVerify` on that vector fails in this
    /// build. We instead use tv3()'s 5th test pair (index 4), which uses valid
    /// in-range parameters (t=19) and round-trips successfully:
    ///   passwd="^T5H$JYt39n%K*j:W]!1s?vg!:jGi]Ax?..l7[p0v:1jHTpla9;]bUN;?bWyCbtqg "
    ///   out="$argon2id$v=19$m=4096,t=19,p=1$PkEgMTYtYnl0ZXMgc2FsdA$ltB/ue1kPtBMBGfsysMpPigE6hiNEKZ9vs8vLNVDQGA"
    /// (verified against github.com/jedisct1/libsodium test/default/pwhash_argon2id.c).
    func testSodiumArgon2idMatchesLibsodiumOwnTestVector() throws {
        let sodium = Sodium()
        let passwd = Array("^T5H$JYt39n%K*j:W]!1s?vg!:jGi]Ax?..l7[p0v:1jHTpla9;]bUN;?bWyCbtqg ".utf8)
        let referenceHash = "$argon2id$v=19$m=4096,t=19,p=1$PkEgMTYtYnl0ZXMgc2FsdA$ltB/ue1kPtBMBGfsysMpPigE6hiNEKZ9vs8vLNVDQGA"

        XCTAssertTrue(sodium.pwHash.strVerify(hash: referenceHash, passwd: passwd))

        guard let hashStr = sodium.pwHash.str(
            passwd: passwd,
            opsLimit: 19,
            memLimit: 4096 * 1024 // m= in the encoded string is KiB; str()'s memLimit is bytes.
        ) else {
            return XCTFail("pwHash.str returned nil")
        }
        // Verify structure and parameter compatibility, not byte-for-byte equality
        // (salt is generated randomly on each str() call, so the string differs
        // from the reference; use verify above for a deterministic check):
        XCTAssertTrue(hashStr.hasPrefix("$argon2id$v=19$m=4096,t=19,p=1$"))
        XCTAssertTrue(sodium.pwHash.strVerify(hash: hashStr, passwd: passwd))
    }

    func testTransformedKeyIsDeterministicForSameInputs() throws {
        var kdf = VariantDictionary()
        kdf.items["$UUID"] = .byteArray(KdbxKdfUUID.argon2id)
        kdf.items["S"] = .byteArray(Data(repeating: 0x02, count: 16))
        kdf.items["M"] = .uint64(19 * 1024 * 1024) // 19 MiB — OWASP-recommended minimum
        kdf.items["I"] = .uint64(2)
        kdf.items["P"] = .uint32(1)
        kdf.items["V"] = .uint32(0x13)

        let composite = Data("test-master-password".utf8)
        let key1 = try KeyDerivation.transformedKey(compositeKey: composite, kdfParameters: kdf)
        let key2 = try KeyDerivation.transformedKey(compositeKey: composite, kdfParameters: kdf)

        XCTAssertEqual(key1, key2)
        XCTAssertEqual(key1.count, 32)
    }

    /// Known-answer test binding `KeyDerivation.transformedKey`'s actual raw 32-byte
    /// output to an INDEPENDENTLY computed reference value, so a param-mapping bug
    /// (wrong salt, swapped opsLimit/memLimit, truncated output, etc.) would be caught
    /// even though it would still be deterministic and 32 bytes long.
    ///
    /// The expected output was computed independently of this codebase using Python's
    /// `argon2-cffi` 25.1.0 (which wraps the P-H-C reference `phc-winner-argon2` C
    /// implementation — a different Argon2id implementation than libsodium's fork that
    /// swift-sodium/this file calls), via:
    ///
    /// ```python
    /// from argon2.low_level import hash_secret_raw, Type
    /// hash_secret_raw(
    ///     secret=b"correct horse battery staple",
    ///     salt=bytes(range(16)),          # 0x00,0x01,...,0x0F
    ///     time_cost=2,                    # matches "I"
    ///     memory_cost=19 * 1024,          # KiB; 19*1024*1024 bytes matches "M"
    ///     parallelism=1,                  # matches "P"
    ///     hash_len=32,
    ///     type=Type.ID,
    ///     version=19,                     # 0x13, matches "V"
    /// )
    /// ```
    /// which produced the raw output hex `818259b6310026a8e0dbac5d2e6927abcfdb07b32258fac4f61b18b80f929085`
    /// (32 bytes). No secret/associatedData were used (KDBX4/libsodium's public API
    /// don't support them), so this vector is directly reproducible via the
    /// production `transformedKey` path.
    func testTransformedKeyMatchesIndependentArgon2idKnownAnswer() throws {
        var kdf = VariantDictionary()
        kdf.items["$UUID"] = .byteArray(KdbxKdfUUID.argon2id)
        kdf.items["S"] = .byteArray(Data((0..<16).map { UInt8($0) })) // 0x00..0x0F
        kdf.items["M"] = .uint64(19 * 1024 * 1024) // 19 MiB, in bytes
        kdf.items["I"] = .uint64(2)
        kdf.items["P"] = .uint32(1)
        kdf.items["V"] = .uint32(0x13)

        let composite = Data("correct horse battery staple".utf8)
        let derived = try KeyDerivation.transformedKey(compositeKey: composite, kdfParameters: kdf)

        let expected = Data([
            0x81, 0x82, 0x59, 0xb6, 0x31, 0x00, 0x26, 0xa8,
            0xe0, 0xdb, 0xac, 0x5d, 0x2e, 0x69, 0x27, 0xab,
            0xcf, 0xdb, 0x07, 0xb3, 0x22, 0x58, 0xfa, 0xc4,
            0xf6, 0x1b, 0x18, 0xb8, 0x0f, 0x92, 0x90, 0x85,
        ])
        XCTAssertEqual(derived, expected)
    }

    // MARK: - AES-KDF

    /// Known-answer test for the AES-KDF `transformedKey` path, computed
    /// independently via Python's `pycryptodome` (AES-256-ECB, not this
    /// codebase's CommonCrypto binding):
    ///
    /// ```python
    /// from Crypto.Cipher import AES
    /// import hashlib
    /// seed = bytes(range(32))               # 0x00..0x1F, matches "S"
    /// composite = bytes([0xAA]*16 + [0xBB]*16)
    /// rounds = 3                              # matches "R"
    /// cipher = AES.new(seed, AES.MODE_ECB)
    /// data = composite
    /// for _ in range(rounds):
    ///     data = cipher.encrypt(data)
    /// final = hashlib.sha256(data).digest()
    /// ```
    /// which produced `df34ca116b7e1c04cb4b60bc813c60abfd27ba9334bdd6a489acb49ae24da9b4`.
    /// This pins the exact algorithm verified against KeePassXC's
    /// `SymmetricCipher::aesKdf()` (Botan's `BlockCipher::encrypt()` applied
    /// in ECB mode to the whole 32-byte buffer, i.e. each 16-byte block
    /// encrypted independently, `R` times, keyed by `S`), followed by a
    /// SHA-256 finalization (`AesKdf::transform()`'s
    /// `CryptoHash::hash(out, CryptoHash::Sha256)`).
    func testTransformedKeyMatchesIndependentAesKdfKnownAnswer() throws {
        var kdf = VariantDictionary()
        kdf.items["$UUID"] = .byteArray(KdbxKdfUUID.aesKdf)
        kdf.items["S"] = .byteArray(Data((0..<32).map { UInt8($0) })) // 0x00..0x1F
        kdf.items["R"] = .uint64(3)

        let composite = Data(repeating: 0xAA, count: 16) + Data(repeating: 0xBB, count: 16)
        let derived = try KeyDerivation.transformedKey(compositeKey: composite, kdfParameters: kdf)

        let expected = Data([
            0xdf, 0x34, 0xca, 0x11, 0x6b, 0x7e, 0x1c, 0x04,
            0xcb, 0x4b, 0x60, 0xbc, 0x81, 0x3c, 0x60, 0xab,
            0xfd, 0x27, 0xba, 0x93, 0x34, 0xbd, 0xd6, 0xa4,
            0x89, 0xac, 0xb4, 0x9a, 0xe2, 0x4d, 0xa9, 0xb4,
        ])
        XCTAssertEqual(derived, expected)
    }

    /// Real-world KDBX4 files (including pykeepass-generated fixtures) tag
    /// AES-KDF with the legacy `KDF_AES_KDBX3` UUID
    /// (`c9d9f39a-628a-4460-bf74-0d08c18a4fea`), not the `KDF_AES_KDBX4`
    /// UUID — per KeePassXC's `KeePass2::uuidToKdf()`, both construct the
    /// identical `AesKdf` algorithm, so both must be accepted on read.
    func testAesKdfAcceptsLegacyKdbx3UUID() throws {
        var kdf = VariantDictionary()
        kdf.items["$UUID"] = .byteArray(KdbxKdfUUID.aesKdfLegacyKdbx3)
        kdf.items["S"] = .byteArray(Data((0..<32).map { UInt8($0) }))
        kdf.items["R"] = .uint64(3)

        let composite = Data(repeating: 0xAA, count: 16) + Data(repeating: 0xBB, count: 16)
        let derived = try KeyDerivation.transformedKey(compositeKey: composite, kdfParameters: kdf)

        let expected = Data([
            0xdf, 0x34, 0xca, 0x11, 0x6b, 0x7e, 0x1c, 0x04,
            0xcb, 0x4b, 0x60, 0xbc, 0x81, 0x3c, 0x60, 0xab,
            0xfd, 0x27, 0xba, 0x93, 0x34, 0xbd, 0xd6, 0xa4,
            0x89, 0xac, 0xb4, 0x9a, 0xe2, 0x4d, 0xa9, 0xb4,
        ])
        XCTAssertEqual(derived, expected)
    }

    func testAesKdfIsDeterministicForSameInputs() throws {
        var kdf = VariantDictionary()
        kdf.items["$UUID"] = .byteArray(KdbxKdfUUID.aesKdf)
        kdf.items["S"] = .byteArray(Data(repeating: 0x07, count: 32))
        kdf.items["R"] = .uint64(1000)

        var composite = Data("test-master-password".utf8)
        composite.append(Data(repeating: 0, count: 32 - composite.count))
        let key1 = try KeyDerivation.transformedKey(compositeKey: composite, kdfParameters: kdf)
        let key2 = try KeyDerivation.transformedKey(compositeKey: composite, kdfParameters: kdf)

        XCTAssertEqual(key1, key2)
        XCTAssertEqual(key1.count, 32)
    }

    func testAesKdfMissingParametersThrowsInvalidParameters() {
        var kdf = VariantDictionary()
        kdf.items["$UUID"] = .byteArray(KdbxKdfUUID.aesKdf)
        // Missing S and R on purpose.
        XCTAssertThrowsError(try KeyDerivation.transformedKey(compositeKey: Data(repeating: 0, count: 32), kdfParameters: kdf)) { error in
            guard case KeyDerivationError.invalidParameters = error else {
                return XCTFail("expected invalidParameters, got \(error)")
            }
        }
    }

    func testAesKdfWrongSeedLengthThrowsInvalidParameters() {
        var kdf = VariantDictionary()
        kdf.items["$UUID"] = .byteArray(KdbxKdfUUID.aesKdf)
        kdf.items["S"] = .byteArray(Data(repeating: 0x01, count: 16)) // wrong: must be 32 bytes
        kdf.items["R"] = .uint64(10)
        XCTAssertThrowsError(try KeyDerivation.transformedKey(compositeKey: Data(repeating: 0, count: 32), kdfParameters: kdf)) { error in
            guard case KeyDerivationError.invalidParameters = error else {
                return XCTFail("expected invalidParameters, got \(error)")
            }
        }
    }

    func testUnsupportedKdfThrows() {
        var kdf = VariantDictionary()
        kdf.items["$UUID"] = .byteArray(Data(repeating: 0xFF, count: 16))
        XCTAssertThrowsError(try KeyDerivation.transformedKey(compositeKey: Data(), kdfParameters: kdf)) { error in
            guard case KeyDerivationError.unsupportedKdf = error else {
                return XCTFail("expected unsupportedKdf, got \(error)")
            }
        }
    }

    func testMissingParametersThrowsInvalidParameters() {
        var kdf = VariantDictionary()
        kdf.items["$UUID"] = .byteArray(KdbxKdfUUID.argon2id)
        // Missing S, M, I, P, V on purpose.
        XCTAssertThrowsError(try KeyDerivation.transformedKey(compositeKey: Data(), kdfParameters: kdf)) { error in
            guard case KeyDerivationError.invalidParameters = error else {
                return XCTFail("expected invalidParameters, got \(error)")
            }
        }
    }

    /// `ARGON2_MIN_LANES` (1) in argon2.h — P=0 is below it. (P=2, this
    /// test's old value, is valid as of this task; see
    /// `testTransformedKeyAcceptsParallelismTwoKnownAnswer`.)
    func testParallelismOutOfRangeThrowsInvalidParameters() {
        var kdf = VariantDictionary()
        kdf.items["$UUID"] = .byteArray(KdbxKdfUUID.argon2id)
        kdf.items["S"] = .byteArray(Data(repeating: 0x02, count: 16))
        kdf.items["M"] = .uint64(19 * 1024 * 1024)
        kdf.items["I"] = .uint64(2)
        kdf.items["P"] = .uint32(0) // below ARGON2_MIN_LANES
        kdf.items["V"] = .uint32(0x13)

        XCTAssertThrowsError(try KeyDerivation.transformedKey(compositeKey: Data(), kdfParameters: kdf)) { error in
            guard case KeyDerivationError.invalidParameters = error else {
                return XCTFail("expected invalidParameters, got \(error)")
            }
        }
    }

    /// Known-answer test at P=2 — computed independently via argon2-cffi 25.1.0,
    /// same secret/salt/I/M/V as `testTransformedKeyMatchesIndependentArgon2idKnownAnswer`:
    ///
    /// ```python
    /// from argon2.low_level import hash_secret_raw, Type
    /// hash_secret_raw(
    ///     secret=b"correct horse battery staple", salt=bytes(range(16)),
    ///     time_cost=2, memory_cost=19 * 1024, parallelism=2,
    ///     hash_len=32, type=Type.ID, version=19,
    /// )
    /// ```
    func testTransformedKeyAcceptsParallelismTwoKnownAnswer() throws {
        var kdf = VariantDictionary()
        kdf.items["$UUID"] = .byteArray(KdbxKdfUUID.argon2id)
        kdf.items["S"] = .byteArray(Data((0..<16).map { UInt8($0) }))
        kdf.items["M"] = .uint64(19 * 1024 * 1024)
        kdf.items["I"] = .uint64(2)
        kdf.items["P"] = .uint32(2)
        kdf.items["V"] = .uint32(0x13)

        let composite = Data("correct horse battery staple".utf8)
        let derived = try KeyDerivation.transformedKey(compositeKey: composite, kdfParameters: kdf)

        let expected = Data([
            0xd8, 0x7f, 0x42, 0x24, 0x13, 0x02, 0xfe, 0x7d,
            0x74, 0xbf, 0xac, 0xd8, 0x66, 0xc9, 0x24, 0x57,
            0xa4, 0x96, 0x99, 0xe8, 0xa5, 0x0d, 0x19, 0xac,
            0x8b, 0x46, 0x27, 0x3b, 0x2c, 0x58, 0x1a, 0x90,
        ])
        XCTAssertEqual(derived, expected)
    }

    /// Same, at P=4 (`argon2-cffi`, identical parameters otherwise, `parallelism=4`).
    func testTransformedKeyAcceptsParallelismFourKnownAnswer() throws {
        var kdf = VariantDictionary()
        kdf.items["$UUID"] = .byteArray(KdbxKdfUUID.argon2id)
        kdf.items["S"] = .byteArray(Data((0..<16).map { UInt8($0) }))
        kdf.items["M"] = .uint64(19 * 1024 * 1024)
        kdf.items["I"] = .uint64(2)
        kdf.items["P"] = .uint32(4)
        kdf.items["V"] = .uint32(0x13)

        let composite = Data("correct horse battery staple".utf8)
        let derived = try KeyDerivation.transformedKey(compositeKey: composite, kdfParameters: kdf)

        let expected = Data([
            0xb9, 0x80, 0x9d, 0x33, 0x24, 0x60, 0x01, 0x14,
            0x00, 0x27, 0x2c, 0xf6, 0x70, 0x66, 0xfc, 0x28,
            0x00, 0xf1, 0x70, 0xcf, 0x06, 0x6c, 0x02, 0xe2,
            0x20, 0x20, 0xc1, 0xf3, 0xd1, 0x6f, 0xb5, 0x76,
        ])
        XCTAssertEqual(derived, expected)
    }

    /// A hostile or malformed KDBX4 header can claim any `M` (memory, in
    /// bytes) representable in a `UInt64` — nothing upstream in
    /// `VariantDictionary`/`KdbxOuterHeader` bounds-checks it. The vendored
    /// Argon2 library's `m_cost` parameter is a `UInt32` of KIBIBYTES, so
    /// this pins that an out-of-range value is rejected with
    /// `.invalidParameters` rather than trapping the process via an
    /// overflowing `UInt32(_:)` narrowing conversion.
    func testArgon2idMemoryOutOfRangeThrowsInvalidParameters() {
        var kdf = VariantDictionary()
        kdf.items["$UUID"] = .byteArray(KdbxKdfUUID.argon2id)
        kdf.items["S"] = .byteArray(Data(repeating: 0x02, count: 16))
        // (UInt32.max + 1) KiB, in bytes: one KiB step past what the
        // vendored library's `m_cost` parameter can represent.
        kdf.items["M"] = .uint64((UInt64(UInt32.max) + 1) * 1024)
        kdf.items["I"] = .uint64(2)
        kdf.items["P"] = .uint32(1)
        kdf.items["V"] = .uint32(0x13)

        XCTAssertThrowsError(try KeyDerivation.transformedKey(compositeKey: Data(), kdfParameters: kdf)) { error in
            guard case KeyDerivationError.invalidParameters = error else {
                return XCTFail("expected invalidParameters, got \(error)")
            }
        }
    }

    /// Same shape as the memory test above, but for `I` (iterations): the
    /// vendored library's `t_cost` parameter is also a `UInt32`, and a
    /// header can claim any `UInt64` value for it.
    func testArgon2idIterationsOutOfRangeThrowsInvalidParameters() {
        var kdf = VariantDictionary()
        kdf.items["$UUID"] = .byteArray(KdbxKdfUUID.argon2id)
        kdf.items["S"] = .byteArray(Data(repeating: 0x02, count: 16))
        kdf.items["M"] = .uint64(19 * 1024 * 1024)
        // One past what `t_cost: UInt32` can represent.
        kdf.items["I"] = .uint64(UInt64(UInt32.max) + 1)
        kdf.items["P"] = .uint32(1)
        kdf.items["V"] = .uint32(0x13)

        XCTAssertThrowsError(try KeyDerivation.transformedKey(compositeKey: Data(), kdfParameters: kdf)) { error in
            guard case KeyDerivationError.invalidParameters = error else {
                return XCTFail("expected invalidParameters, got \(error)")
            }
        }
    }

    /// Known-answer test with a 32-byte salt — the exact shape every real KDBX4
    /// file uses, and the constraint this task lifts. Computed independently via
    /// argon2-cffi 25.1.0 (same secret/I/M/P/V as
    /// `testTransformedKeyMatchesIndependentArgon2idKnownAnswer`, only the salt
    /// differs — 32 bytes 0x00..0x1F instead of 16 bytes 0x00..0x0F):
    ///
    /// ```python
    /// from argon2.low_level import hash_secret_raw, Type
    /// hash_secret_raw(
    ///     secret=b"correct horse battery staple",
    ///     salt=bytes(range(32)),
    ///     time_cost=2, memory_cost=19 * 1024, parallelism=1,
    ///     hash_len=32, type=Type.ID, version=19,
    /// )
    /// ```
    func testTransformedKeyAccepts32ByteSaltKnownAnswer() throws {
        var kdf = VariantDictionary()
        kdf.items["$UUID"] = .byteArray(KdbxKdfUUID.argon2id)
        kdf.items["S"] = .byteArray(Data((0..<32).map { UInt8($0) })) // 0x00..0x1F
        kdf.items["M"] = .uint64(19 * 1024 * 1024)
        kdf.items["I"] = .uint64(2)
        kdf.items["P"] = .uint32(1)
        kdf.items["V"] = .uint32(0x13)

        let composite = Data("correct horse battery staple".utf8)
        let derived = try KeyDerivation.transformedKey(compositeKey: composite, kdfParameters: kdf)

        let expected = Data([
            0x09, 0x2d, 0x6e, 0x91, 0x98, 0x78, 0x40, 0xe6,
            0x3e, 0x2f, 0xac, 0x5e, 0x18, 0x7a, 0xc5, 0xd2,
            0x9b, 0x48, 0x9f, 0x05, 0x59, 0x79, 0x71, 0xfd,
            0x65, 0x54, 0x55, 0x5a, 0x1a, 0x20, 0xce, 0x2a,
        ])
        XCTAssertEqual(derived, expected)
    }

    /// The Argon2 reference library's own minimum (`ARGON2_MIN_SALT_LENGTH` in
    /// `argon2.h`, an object-like macro that does not bridge into Swift — see
    /// the comment at the guard site) — anything shorter is a malformed or
    /// truncated header, not "try it and see what the library says."
    func testSaltShorterThanMinimumThrowsInvalidParameters() {
        var kdf = VariantDictionary()
        kdf.items["$UUID"] = .byteArray(KdbxKdfUUID.argon2id)
        kdf.items["S"] = .byteArray(Data(repeating: 0x01, count: 7)) // below the 8-byte minimum
        kdf.items["M"] = .uint64(19 * 1024 * 1024)
        kdf.items["I"] = .uint64(2)
        kdf.items["P"] = .uint32(1)
        kdf.items["V"] = .uint32(0x13)

        XCTAssertThrowsError(try KeyDerivation.transformedKey(compositeKey: Data(), kdfParameters: kdf)) { error in
            guard case KeyDerivationError.invalidParameters = error else {
                return XCTFail("expected invalidParameters, got \(error)")
            }
        }
    }

    func testMasterKeyAndHmacKeyBaseDiffer() {
        let seed = Data(repeating: 0x01, count: 32)
        let transformed = Data(repeating: 0x02, count: 32)
        let masterKey = KeyDerivation.masterKey(masterSeed: seed, transformedKey: transformed)
        let hmacBase = KeyDerivation.hmacKeyBase(masterSeed: seed, transformedKey: transformed)

        XCTAssertEqual(masterKey.count, 32)
        XCTAssertEqual(hmacBase.count, 64)
        XCTAssertNotEqual(masterKey, hmacBase.prefix(32))
    }
}
