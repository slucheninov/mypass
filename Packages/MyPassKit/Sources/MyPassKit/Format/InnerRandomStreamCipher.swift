import Foundation
import CryptoKit
import Clibsodium

/// `InnerRandomStreamID` — the KDBX4 inner-header value identifying which
/// stream cipher obfuscates individual protected field values (e.g.
/// passwords) inside the decrypted XML payload. This is a *different* layer
/// from the outer cipher (Tasks 9/10, which protects the whole HMAC block
/// stream) and uses different key-derivation rules entirely.
enum InnerRandomStreamID: UInt32 {
    case arcFourVariant = 1
    case salsa20 = 2
    case chaCha20 = 3
}

enum InnerRandomStreamCipherError: Error, Equatable {
    case unsupportedStream(UInt32)
}

/// KeePass-specific fixed 8-byte nonce for the inner Salsa20 stream. This is
/// NOT derived from the file in any way — it is a hardcoded constant shared
/// by all KDBX4 files using Salsa20 as `InnerRandomStreamID`. Verified
/// byte-for-byte against KeePassXC's `KeePass2::INNER_STREAM_SALSA20_IV`
/// (`src/format/KeePass2.cpp`, upstream master as of 2026-07-21):
/// `const QByteArray KeePass2::INNER_STREAM_SALSA20_IV("\xe8\x30\x09\x4b\x97\x20\x5d\x2a");`
private let salsa20FixedNonce: [UInt8] = [0xE8, 0x30, 0x09, 0x4B, 0x97, 0x20, 0x5D, 0x2A]

/// Decrypts/obfuscates individual protected string values inside the KDBX4
/// inner XML (e.g. `<Value Protected="True">`), as distinct from the outer
/// cipher (`AES256CBCCipher`/`ChaCha20StreamCipher` from Tasks 9/10) that
/// protects the whole HMAC block stream payload.
///
/// Key derivation (verified against KeePassXC's `KeePass2RandomStream::init`,
/// `src/format/KeePass2RandomStream.cpp`):
/// - Salsa20: cipher key = SHA256(rawKey) (32 bytes); nonce = the fixed
///   8-byte `salsa20FixedNonce` constant above (not derived from the file).
/// - ChaCha20: a single SHA512(rawKey) digest (64 bytes) is split — the
///   first 32 bytes become the ChaCha20 key, the next 12 bytes become the
///   nonce. This is NOT the same key/nonce derivation as Task 10's outer
///   ChaCha20 (which takes key/IV directly from the KDBX4 header).
///
/// `rawKey` is the raw `InnerRandomStreamKey` bytes from the inner header
/// (arbitrary length) — NOT the 32-byte `masterKey` used for the outer
/// cipher.
///
/// `ArcFourVariant` (`InnerRandomStreamID == 1`) is not implemented; no KDBX4
/// writer in this plan emits it, and no known real-world files use it, so
/// `init` throws `.unsupportedStream` rather than attempting an RC4
/// implementation.
final class InnerRandomStreamCipher {
    private enum Algo {
        case salsa20(key: [UInt8])
        case chaCha20(key: [UInt8], nonce: [UInt8])
    }

    private let algo: Algo
    private var counter: UInt64 = 0
    private var keystreamBuffer: [UInt8] = []
    private var bufferOffset = 0

    init(streamID: InnerRandomStreamID, rawKey: Data) throws {
        switch streamID {
        case .arcFourVariant:
            throw InnerRandomStreamCipherError.unsupportedStream(InnerRandomStreamID.arcFourVariant.rawValue)
        case .salsa20:
            let key = Array(Data(SHA256.hash(data: rawKey)))
            algo = .salsa20(key: key)
        case .chaCha20:
            let hashed = Array(Data(SHA512.hash(data: rawKey)))
            let key = Array(hashed[0..<32])
            let nonce = Array(hashed[32..<44])
            algo = .chaCha20(key: key, nonce: nonce)
        }
    }

    /// Returns the next `count` bytes of continuous keystream. XOR-ing this
    /// against protected values, in the order they appear in the XML, yields
    /// plaintext (and XOR is its own inverse, so the same call sequence
    /// re-obfuscates plaintext back to the original ciphertext). Calls are
    /// cumulative: a second call continues the stream exactly where the
    /// previous call left off, regardless of how the byte counts are split
    /// across calls.
    func nextBytes(_ count: Int) -> Data {
        guard count > 0 else { return Data() }

        var result = [UInt8]()
        result.reserveCapacity(count)
        while result.count < count {
            if bufferOffset >= keystreamBuffer.count {
                keystreamBuffer = generateBlock()
                bufferOffset = 0
            }
            let take = min(count - result.count, keystreamBuffer.count - bufferOffset)
            result.append(contentsOf: keystreamBuffer[bufferOffset..<(bufferOffset + take)])
            bufferOffset += take
        }
        return Data(result)
    }

    /// Generates one 64-byte keystream block starting at the current block
    /// `counter`, then advances the counter by one block (both libsodium
    /// primitives below produce 64-byte blocks per counter increment).
    private func generateBlock() -> [UInt8] {
        let blockSize = 64
        let zeros = [UInt8](repeating: 0, count: blockSize)
        var out = [UInt8](repeating: 0, count: blockSize)

        switch algo {
        case .salsa20(let key):
            var nonce = salsa20FixedNonce
            var keyCopy = key
            // crypto_stream_salsa20_xor_ic: 8-byte nonce, 64-bit block
            // counter (units of 64-byte blocks) — matches libsodium
            // 1.0.22's crypto_stream_salsa20.h signature.
            _ = crypto_stream_salsa20_xor_ic(&out, zeros, UInt64(blockSize), &nonce, counter, &keyCopy)
        case .chaCha20(let key, let nonce):
            var nonceCopy = nonce
            var keyCopy = key
            // crypto_stream_chacha20_ietf_xor_ic: 12-byte nonce, 32-bit
            // block counter (IETF variant) — the counter parameter is
            // uint32_t, unlike Salsa20's uint64_t, per
            // crypto_stream_chacha20.h.
            _ = crypto_stream_chacha20_ietf_xor_ic(&out, zeros, UInt64(blockSize), &nonceCopy, UInt32(truncatingIfNeeded: counter), &keyCopy)
        }

        counter += 1
        return out
    }
}
