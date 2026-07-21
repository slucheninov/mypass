import XCTest
import Sodium
@testable import MyPassKit

final class KeyDerivationTests: XCTestCase {
    /// Кросс-проверка самой обёртки над swift-sodium/libsodium: тестовый вектор
    /// взят из тестового набора libsodium (test/default/pwhash_argon2id.c, tv3()),
    /// НЕ из "сырых" эталонных векторов Argon2 (phc-winner-argon2/kats), т.к.
    /// libsodium's crypto_pwhash API не поддерживает опциональные secret/associatedData
    /// параметры "сырого" Argon2 (что и не нужно — KDBX4 их тоже не использует, см.
    /// Global Constraints). Проверяем через encoded-строку, т.к. это именно то, что
    /// зафиксировано в исходнике теста libsodium.
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
        // Проверяем структуру и совместимость параметров, а не байт-в-байт равенство
        // (соль генерируется случайно при каждом вызове str(), поэтому строка отличается
        // от эталонной; для детерминированной проверки используем verify выше):
        XCTAssertTrue(hashStr.hasPrefix("$argon2id$v=19$m=4096,t=19,p=1$"))
        XCTAssertTrue(sodium.pwHash.strVerify(hash: hashStr, passwd: passwd))
    }

    func testTransformedKeyIsDeterministicForSameInputs() throws {
        var kdf = VariantDictionary()
        kdf.items["$UUID"] = .byteArray(KdbxKdfUUID.argon2id)
        kdf.items["S"] = .byteArray(Data(repeating: 0x02, count: 16))
        kdf.items["M"] = .uint64(19 * 1024 * 1024) // 19 MiB — минимум OWASP-рекомендаций
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

    func testUnsupportedParallelismThrowsInvalidParameters() {
        var kdf = VariantDictionary()
        kdf.items["$UUID"] = .byteArray(KdbxKdfUUID.argon2id)
        kdf.items["S"] = .byteArray(Data(repeating: 0x02, count: 16))
        kdf.items["M"] = .uint64(19 * 1024 * 1024)
        kdf.items["I"] = .uint64(2)
        kdf.items["P"] = .uint32(2) // unsupported by libsodium's public crypto_pwhash API
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
