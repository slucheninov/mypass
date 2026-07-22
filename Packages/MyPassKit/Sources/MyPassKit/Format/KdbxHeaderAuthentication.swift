import Foundation
import CryptoKit

/// Derivation of the per-block HMAC keys used both for verifying/producing
/// the outer-header HMAC (this file) and for the HMAC block stream body
/// (Task 8, which reuses `blockKey` rather than redefining it).
enum HmacBlockStream {
    /// Ki = SHA512(UInt64LE(i) ‖ hmacKeyBase)
    static func blockKey(index: UInt64, hmacKeyBase: Data) -> Data {
        var input = Data(withUnsafeBytes(of: index.littleEndian) { Data($0) })
        input.append(hmacKeyBase)
        return Data(SHA512.hash(data: input))
    }
}

/// Computes the KDBX4 outer-header authentication values: `HeaderSHA256`
/// (a plain integrity checksum) and `HeaderHMAC-SHA256` (an authenticated
/// checksum keyed off the master key, per the Global Constraints' HMAC
/// key-derivation formula).
enum KdbxHeaderAuthentication {
    /// HeaderSHA256 = SHA-256(raw), where `raw` is the exact header byte
    /// range (Signature + Version + OuterHeaderFields through EndOfHeader
    /// inclusive) — i.e. `KdbxOuterHeader.rawHeaderBytes` on read, or
    /// signature+version bytes followed by `serialize()`'s output on write.
    static func sha256(ofHeader raw: Data) -> Data {
        Data(SHA256.hash(data: raw))
    }

    /// HeaderHMAC-SHA256 = HMAC-SHA256(key: K(UInt64.max), message: raw)
    ///
    /// `hmacKeyBase` is the output of `KeyDerivation.hmacKeyBase(masterSeed:transformedKey:)`
    /// (Task 7) — NOT the master seed or transformed key directly. The
    /// header HMAC uses the same per-block key derivation as the HMAC block
    /// stream body, but with the reserved block index `UInt64.max`
    /// (0xFFFFFFFFFFFFFFFF) rather than a real block index, per the KDBX4
    /// format's Global Constraints.
    static func hmacSHA256(ofHeader raw: Data, hmacKeyBase: Data) -> Data {
        let blockKey = HmacBlockStream.blockKey(index: UInt64.max, hmacKeyBase: hmacKeyBase)
        let key = SymmetricKey(data: blockKey)
        let mac = HMAC<SHA256>.authenticationCode(for: raw, using: key)
        return Data(mac)
    }
}
