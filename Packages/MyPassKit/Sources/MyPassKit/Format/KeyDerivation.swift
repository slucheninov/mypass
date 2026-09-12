import Foundation
import CryptoKit
import CArgon2

enum KeyDerivationError: Error, Equatable {
    case unsupportedKdf(Data)
    case invalidParameters
    case sodiumFailure
}

/// Derives the KDBX4 `transformedKey` from a composite key and the
/// KDF parameters stored in the outer header's `VariantDictionary`
/// (Task 3), plus the final `masterKey`/`hmacKeyBase` values consumed by
/// header authentication (Task 5) and the HMAC block stream (Task 7).
///
/// Argon2id (`KdbxKdfUUID.argon2id`) and AES-KDF (`KdbxKdfUUID.aesKdf`) are
/// supported for reading. KDBX4 files using Argon2d are still rejected with
/// `.unsupportedKdf` rather than silently mis-deriving a key. Write support
/// (`KdbxDatabase.save`) remains Argon2id-only per the plan's Global
/// Constraints — AES-KDF here is read-only.
enum KeyDerivation {
    /// Reads `$UUID` from `kdfParameters` and dispatches to the matching KDF.
    static func transformedKey(compositeKey: Data, kdfParameters: VariantDictionary) throws -> Data {
        guard case .byteArray(let uuid)? = kdfParameters.items["$UUID"] else {
            throw KeyDerivationError.invalidParameters
        }
        switch uuid {
        case KdbxKdfUUID.argon2id:
            return try argon2id(compositeKey: compositeKey, params: kdfParameters)
        case KdbxKdfUUID.aesKdf, KdbxKdfUUID.aesKdfLegacyKdbx3:
            return try aesKdf(compositeKey: compositeKey, params: kdfParameters)
        default:
            throw KeyDerivationError.unsupportedKdf(uuid)
        }
    }

    /// Argon2id key derivation via the vendored `CArgon2` reference library.
    ///
    /// VariantDictionary keys (verified byte-for-byte against KeePassXC's
    /// `src/format/KeePass2.cpp`, where `KeePass2::KDFPARAM_ARGON2_SALT` etc.
    /// are defined as `QStringLiteral`s):
    ///   - `S` = salt
    ///   - `M` = memory, in **bytes** (converted to the KiB units the
    ///     vendored library expects — see the comment at the conversion
    ///     site below)
    ///   - `I` = iterations / opslimit
    ///   - `P` = parallelism (lanes)
    ///   - `V` = Argon2 version (0x13 = v19)
    ///
    /// The `parallelism == 1` and salt-length guards below are about to be
    /// relaxed in Tasks 3–4: the vendored library has no such limitations
    /// itself, but this task's scope is swapping the backend with zero
    /// observable behaviour change, one constraint at a time.
    ///
    /// `V` is still required to be present and equal to 0x13 so a v0x10
    /// (legacy) file is rejected rather than silently mis-derived; the
    /// KDBX4 Global Constraints only mandate v0x13 for Argon2id.
    private static func argon2id(compositeKey: Data, params: VariantDictionary) throws -> Data {
        guard case .byteArray(let salt)? = params.items["S"],
              case .uint64(let memoryBytes)? = params.items["M"],
              case .uint64(let iterations)? = params.items["I"],
              case .uint32(let parallelism)? = params.items["P"],
              case .uint32(let version)? = params.items["V"] else {
            throw KeyDerivationError.invalidParameters
        }
        // The Argon2 reference library's own minimum (ARGON2_MIN_SALT_LENGTH
        // in argon2.h, defined as `#define ARGON2_MIN_SALT_LENGTH
        // UINT32_C(8)`) — an object-like macro using UINT32_C, which does
        // NOT bridge into Swift (confirmed: referencing it from Swift code
        // fails to compile, "cannot find 'ARGON2_MIN_SALT_LENGTH' in
        // scope" — Clang's importer does not evaluate object-like macros
        // built from other macros). The literal 8 below is that same
        // constant, just necessarily hardcoded on the Swift side; if
        // phc-winner-argon2 is ever upgraded, re-check this value against
        // the vendored argon2.h rather than assuming it's unchanged.
        guard salt.count >= 8 else {
            throw KeyDerivationError.invalidParameters
        }
        guard parallelism == 1 else {
            throw KeyDerivationError.invalidParameters
        }
        guard version == 0x13 else {
            throw KeyDerivationError.invalidParameters
        }

        // KDBX gives `M` in bytes; the vendored Argon2 reference library's
        // `m_cost` parameter is in KIBIBYTES (1024-byte units) — see
        // phc-winner-argon2's `include/argon2.h`, `Argon2_Context.m_cost`'s
        // doc comment ("amount of memory requested (KB)"), and
        // `argon2_hash`'s own doc comment. This conversion happens in
        // exactly ONE place in this codebase — do not duplicate it
        // elsewhere (Task 5 shares this same call site for Argon2d rather
        // than copying the conversion into a second function).
        //
        // Getting it wrong does not throw or crash: `argon2_hash` accepts
        // any `m_cost` in its valid range and derives A key, just not the
        // RIGHT key. An off-by-1024 error here silently derives a key
        // that is, from the outside, bit-for-bit indistinguishable from
        // what a wrong master password would produce — the vault just
        // fails to open, with nothing pointing at this line. The only
        // thing that can catch a self-consistent-but-wrong conversion
        // factor is a known-answer vector computed by a wholly
        // independent Argon2id implementation — see
        // `testTransformedKeyMatchesIndependentArgon2idKnownAnswer`,
        // which pins exactly this path with M = 19 * 1024 * 1024 bytes.
        //
        // The conversion is CHECKED, not a plain `UInt32(_:)` narrowing:
        // `M` and `I` are `UInt64` values read straight out of the
        // VariantDictionary, with nothing upstream in
        // `VariantDictionary`/`KdbxOuterHeader` bounds-checking them
        // against what the vendored library's `UInt32` `m_cost`/`t_cost`
        // parameters can hold. Swift's plain `UInt32(_:)` initializer
        // traps on overflow — it does not throw — so a malformed or
        // hostile header claiming, say, `M` at or above ~4.4 TB would
        // crash the whole app while merely opening a file. `UInt32(exactly:)`
        // turns that into a typed `.invalidParameters` the caller can
        // handle, matching every other malformed-header case in this
        // function.
        guard let memoryKibibytes = UInt32(exactly: memoryBytes / 1024),
              let iterations32 = UInt32(exactly: iterations) else {
            throw KeyDerivationError.invalidParameters
        }

        var hash = [UInt8](repeating: 0, count: 32)
        let compositeKeyBytes = [UInt8](compositeKey)
        let saltBytes = [UInt8](salt)
        let result = compositeKeyBytes.withUnsafeBufferPointer { pwdPtr in
            saltBytes.withUnsafeBufferPointer { saltPtr in
                hash.withUnsafeMutableBufferPointer { hashPtr in
                    argon2_hash(
                        iterations32, memoryKibibytes, parallelism,
                        pwdPtr.baseAddress, pwdPtr.count,
                        saltPtr.baseAddress, saltPtr.count,
                        hashPtr.baseAddress, hashPtr.count,
                        nil, 0,
                        Argon2_id, UInt32(ARGON2_VERSION_13.rawValue)
                    )
                }
            }
        }
        guard result == ARGON2_OK.rawValue else {
            throw KeyDerivationError.sodiumFailure
        }
        return Data(hash)
    }

    /// AES-KDF (KeePass's classic key-transformation KDF, `KdbxKdfUUID.aesKdf`):
    /// read support only (write support is out of scope — the plan mandates
    /// Argon2id-only for `save()`).
    ///
    /// VariantDictionary keys (verified against KeePassXC's
    /// `src/crypto/kdf/AesKdf.cpp`/`src/crypto/SymmetricCipher.cpp`, see
    /// `AESECBCipher`'s doc-comment for the exact quoted source):
    ///   - `S` = seed (32 bytes — the AES-256 key for the transform, NOT a
    ///     salt in the Argon2 sense)
    ///   - `R` = rounds (UInt64)
    ///
    /// Algorithm: `transformedKey = SHA256(AES256_ECB_encrypt(compositeKey, key: S)` applied `R` times`)`.
    /// The 32-byte composite key is treated as two independent 16-byte AES
    /// blocks with no chaining (ECB, not CBC) — see `AESECBCipher`.
    private static func aesKdf(compositeKey: Data, params: VariantDictionary) throws -> Data {
        guard case .byteArray(let seed)? = params.items["S"],
              case .uint64(let rounds)? = params.items["R"] else {
            throw KeyDerivationError.invalidParameters
        }
        guard seed.count == 32, compositeKey.count % 16 == 0, !compositeKey.isEmpty else {
            throw KeyDerivationError.invalidParameters
        }

        let transformed: Data
        do {
            transformed = try AESECBCipher.transform(data: compositeKey, key: seed, rounds: rounds)
        } catch {
            throw KeyDerivationError.invalidParameters
        }
        return Data(SHA256.hash(data: transformed))
    }

    /// finalMasterKey = SHA256(masterSeed ‖ transformedKey)
    static func masterKey(masterSeed: Data, transformedKey: Data) -> Data {
        var input = masterSeed
        input.append(transformedKey)
        return Data(SHA256.hash(data: input))
    }

    /// hmacKeyBase = SHA512(masterSeed ‖ transformedKey ‖ 0x01)
    static func hmacKeyBase(masterSeed: Data, transformedKey: Data) -> Data {
        var input = masterSeed
        input.append(transformedKey)
        input.append(0x01)
        return Data(SHA512.hash(data: input))
    }
}
