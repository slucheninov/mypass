import Foundation
import CryptoKit
import Sodium

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
/// Only Argon2id (`KdbxKdfUUID.argon2id`) is supported. KDBX4 files using
/// AES-KDF or Argon2d are rejected with `.unsupportedKdf` rather than
/// silently mis-deriving a key.
enum KeyDerivation {
    /// Reads `$UUID` from `kdfParameters` and dispatches to the matching KDF.
    static func transformedKey(compositeKey: Data, kdfParameters: VariantDictionary) throws -> Data {
        guard case .byteArray(let uuid)? = kdfParameters.items["$UUID"] else {
            throw KeyDerivationError.invalidParameters
        }
        switch uuid {
        case KdbxKdfUUID.argon2id:
            return try argon2id(compositeKey: compositeKey, params: kdfParameters)
        default:
            throw KeyDerivationError.unsupportedKdf(uuid)
        }
    }

    /// Argon2id key derivation via swift-sodium's `crypto_pwhash` binding.
    ///
    /// VariantDictionary keys (verified byte-for-byte against KeePassXC's
    /// `src/format/KeePass2.cpp`, where `KeePass2::KDFPARAM_ARGON2_SALT` etc.
    /// are defined as `QStringLiteral`s):
    ///   - `S` = salt (16 bytes, matches `crypto_pwhash_argon2id_SALTBYTES`)
    ///   - `M` = memory, in **bytes** (matches swift-sodium's `memLimit`,
    ///     which is documented "in bytes" in `PWHash.swift` — no KiB
    ///     conversion needed)
    ///   - `I` = iterations / opslimit
    ///   - `P` = parallelism (lanes)
    ///   - `V` = Argon2 version (0x13 = v19)
    ///
    /// libsodium's public `crypto_pwhash`/`crypto_pwhash_argon2id` API does
    /// not expose a parallelism parameter — its Argon2id implementation is
    /// fixed at a single lane. A KDBX4 file whose `P` != 1 cannot be
    /// correctly derived by this binding, so we reject it with
    /// `.invalidParameters` rather than silently ignoring the requested
    /// parallelism and producing a wrong key.
    ///
    /// `V` is not passed to swift-sodium (there is no version parameter in
    /// its API — it always uses Argon2 v1.3/0x13, the only version libsodium
    /// implements). We still require the field to be present so a v0x10
    /// (legacy) file is rejected rather than silently mis-derived; the KDBX4
    /// Global Constraints only mandate v0x13 for Argon2id.
    private static func argon2id(compositeKey: Data, params: VariantDictionary) throws -> Data {
        guard case .byteArray(let salt)? = params.items["S"],
              case .uint64(let memoryBytes)? = params.items["M"],
              case .uint64(let iterations)? = params.items["I"],
              case .uint32(let parallelism)? = params.items["P"],
              case .uint32(let version)? = params.items["V"] else {
            throw KeyDerivationError.invalidParameters
        }
        guard parallelism == 1 else {
            throw KeyDerivationError.invalidParameters
        }
        guard version == 0x13 else {
            throw KeyDerivationError.invalidParameters
        }

        let sodium = Sodium()
        guard let derived = sodium.pwHash.hash(
            outputLength: 32,
            passwd: [UInt8](compositeKey),
            salt: [UInt8](salt),
            opsLimit: Int(iterations),
            memLimit: Int(memoryBytes),
            alg: .Argon2ID13
        ) else {
            throw KeyDerivationError.sodiumFailure
        }
        return Data(derived)
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
