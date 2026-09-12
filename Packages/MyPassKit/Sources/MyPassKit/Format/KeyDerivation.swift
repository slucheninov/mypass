import Foundation
import CryptoKit
import CArgon2

enum KeyDerivationError: Error, Equatable {
    case unsupportedKdf(Data)
    case invalidParameters
    /// A non-zero return from the vendored Argon2 reference library's
    /// `argon2_hash`, carrying its `Argon2_ErrorCodes` value (as `Int32`)
    /// and the library's own message via `argon2_error_message` — so a
    /// caller can tell a bad-salt-length rejection
    /// (`ARGON2_SALT_TOO_SHORT`, -6) apart from an out-of-memory failure
    /// (`ARGON2_MEMORY_ALLOCATION_ERROR`, -22) apart from any other
    /// rejection, rather than seeing one undifferentiated failure value
    /// for all of them. Replaces `.sodiumFailure`, stale since Task 2
    /// moved the KDF backend off swift-sodium.
    case argon2Failure(code: Int32, message: String)
}

/// Derives the KDBX4 `transformedKey` from a composite key and the
/// KDF parameters stored in the outer header's `VariantDictionary`
/// (Task 3), plus the final `masterKey`/`hmacKeyBase` values consumed by
/// header authentication (Task 5) and the HMAC block stream (Task 7).
///
/// Argon2id (`KdbxKdfUUID.argon2id`), Argon2d (`KdbxKdfUUID.argon2d`) and
/// AES-KDF (`KdbxKdfUUID.aesKdf`) are all supported for reading. Write
/// support (`KdbxDatabase.save`) remains Argon2id-only per the plan's Global
/// Constraints — AES-KDF and Argon2d here are read-only.
enum KeyDerivation {
    /// Reads `$UUID` from `kdfParameters` and dispatches to the matching KDF.
    static func transformedKey(compositeKey: Data, kdfParameters: VariantDictionary) throws -> Data {
        guard case .byteArray(let uuid)? = kdfParameters.items["$UUID"] else {
            throw KeyDerivationError.invalidParameters
        }
        switch uuid {
        case KdbxKdfUUID.argon2id:
            return try argon2id(compositeKey: compositeKey, params: kdfParameters)
        case KdbxKdfUUID.argon2d:
            return try argon2d(compositeKey: compositeKey, params: kdfParameters)
        case KdbxKdfUUID.aesKdf, KdbxKdfUUID.aesKdfLegacyKdbx3:
            return try aesKdf(compositeKey: compositeKey, params: kdfParameters)
        default:
            throw KeyDerivationError.unsupportedKdf(uuid)
        }
    }

    private static func argon2id(compositeKey: Data, params: VariantDictionary) throws -> Data {
        try argon2Derive(type: Argon2_id, compositeKey: compositeKey, params: params)
    }

    private static func argon2d(compositeKey: Data, params: VariantDictionary) throws -> Data {
        try argon2Derive(type: Argon2_d, compositeKey: compositeKey, params: params)
    }

    /// Shared Argon2 key derivation via the vendored `CArgon2` reference
    /// library, for both KDBX4 Argon2 variants this package supports:
    /// Argon2id (`KdbxKdfUUID.argon2id`) and Argon2d (`KdbxKdfUUID.argon2d`).
    /// Deliberately excludes Argon2i (`Argon2_i` in the vendored library's
    /// `Argon2_type` enum) — KDBX4 never uses it, and passing it here by
    /// mistake would not fail, it would silently derive a different, wrong
    /// key. See `testTransformedKeyMatchesIndependentArgon2dKnownAnswer` for
    /// the test that exists specifically to catch a mixed-up `type`
    /// argument at this call site.
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
    /// The salt-length (Task 3) and parallelism (Task 4) constraints
    /// previously inherited from libsodium's public API have both been
    /// lifted: the vendored library's own bounds (`ARGON2_MIN_SALT_LENGTH`,
    /// `ARGON2_MIN_LANES`...`ARGON2_MAX_LANES`) are enforced directly below
    /// instead.
    ///
    /// `V` is still required to be present and equal to 0x13 so a v0x10
    /// (legacy) file is rejected rather than silently mis-derived; the
    /// KDBX4 Global Constraints only mandate v0x13 for Argon2id (and, by
    /// extension, Argon2d — both variants of the same reference algorithm).
    private static func argon2Derive(type: Argon2_type, compositeKey: Data, params: VariantDictionary) throws -> Data {
        guard case .byteArray(let salt)? = params.items["S"],
              case .uint64(let memoryBytes)? = params.items["M"],
              case .uint64(let iterations)? = params.items["I"],
              case .uint32(let parallelism)? = params.items["P"],
              case .uint32(let version)? = params.items["V"] else {
            throw KeyDerivationError.invalidParameters
        }
        // KeePass's Argon2 KDF VariantDictionary also defines `K` (a secret
        // key) and `A` (associated data) — both real, standardized Argon2
        // parameters that a genuine KeePass/KeePassXC vault can carry
        // (KeePass2::KDFPARAM_ARGON2_SECRET_KEY / KDFPARAM_ARGON2_ASSOC_DATA
        // in KeePassXC's `src/format/KeePass2.cpp`). The vendored reference
        // library's `argon2_hash` entry point used below has no parameters
        // for either one — only its lower-level `argon2_ctx` does, and this
        // code does not call it. Silently ignoring `K`/`A` would derive a
        // key from `S`/`M`/`I`/`P`/`V` alone: self-consistent, 32 bytes,
        // deterministic, and WRONG — indistinguishable from a correct
        // derivation until the header HMAC check fails, at which point it
        // looks exactly like a wrong master password with no clue that the
        // real cause is an unsupported KDF parameter. Refusing outright,
        // rather than pretending `K`/`A` don't exist, is what turns that
        // silent wrong-key failure into a diagnosable error.
        guard params.items["K"] == nil, params.items["A"] == nil else {
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
        // ARGON2_MIN_LANES...ARGON2_MAX_LANES in argon2.h — 1 to 2^24-1.
        // Like ARGON2_MIN_SALT_LENGTH above, these are object-like macros
        // built with UINT32_C and do not bridge into Swift; the range
        // below is that same bound, hardcoded. The KDBX header's `P` field
        // is a uint32, so without this upper bound a malformed or hostile
        // header's `P` would be handed to the library unchecked; in
        // practice, real files use small values such as 2 or 4.
        guard (1...16_777_215).contains(parallelism) else {
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
        // elsewhere (this shared function is that one place, used by both
        // the Argon2id and Argon2d wrappers above).
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
        // A sanity ceiling on top of the checked `UInt32(exactly:)`
        // conversion above: that guard only rejects `M` values the vendored
        // library's `m_cost` parameter cannot represent at all (~4.4 TB and
        // up), and everything below that line is handed straight to
        // `argon2_hash`, which allocates it. Key derivation necessarily
        // runs before the header HMAC is verified, so this is reachable
        // pre-authentication: a corrupt or hostile file claiming, say, 32
        // GiB passes every guard above, the allocation succeeds under
        // macOS's memory overcommit, and the process thrashes or is killed
        // while merely opening a file — no password was even checked yet.
        // 4 GiB is the cap: far above anything a real tool produces
        // (KeePassXC's own default `M` is 64 MiB) while still generous
        // enough for any deliberately hardened vault a user might configure.
        guard memoryKibibytes <= 4 * 1024 * 1024 else {
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
                        type, UInt32(ARGON2_VERSION_13.rawValue)
                    )
                }
            }
        }
        guard result == ARGON2_OK.rawValue else {
            let message = String(cString: argon2_error_message(result))
            throw KeyDerivationError.argon2Failure(code: result, message: message)
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
