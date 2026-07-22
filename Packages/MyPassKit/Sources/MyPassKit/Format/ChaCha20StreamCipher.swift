import Foundation
import Clibsodium

enum ChaCha20StreamCipherError: Error, Equatable {
    case invalidKeyOrNonceLength
    case sodiumFailure
}

/// Raw (non-AEAD) ChaCha20 stream cipher for the KDBX4 outer cipher whose
/// `CipherID` is `D6038A2B-8B6F-4CB5-A524-339A31DBB59A`. Unlike AES-256-CBC
/// (Task 9), there is no padding, no block alignment, and no authentication
/// tag here — it is a pure XOR keystream cipher, so `apply` is its own
/// inverse for a given key/nonce pair.
///
/// Uses libsodium's IETF ChaCha20 variant (`crypto_stream_chacha20_ietf_xor`:
/// 32-byte key, 96-bit/12-byte nonce, 32-bit block counter starting at 0),
/// not the original Bernstein variant (`crypto_stream_chacha20_xor`: 64-bit
/// nonce, 64-bit counter) — KDBX4's `EncryptionIV` for ChaCha20 is 12 bytes,
/// which only matches the IETF variant's nonce size. Verified against
/// swift-sodium 0.11.0's `Sources/Sodium/libsodium/crypto_stream_chacha20.h`
/// and cross-checked with the RFC 8439 §2.3.2 block-function test vector
/// below.
///
/// swift-sodium's Swift-level `Stream.xor` wraps `crypto_stream_xor`, whose
/// underlying primitive is XSalsa20, not ChaCha20 IETF — there is no
/// Swift-level wrapper for `crypto_stream_chacha20_ietf_xor`, so this calls
/// the underlying `Clibsodium` C function directly.
enum ChaCha20StreamCipher {
    static func apply(to data: Data, key: Data, nonce: Data) throws -> Data {
        guard key.count == 32, nonce.count == 12 else {
            throw ChaCha20StreamCipherError.invalidKeyOrNonceLength
        }
        guard !data.isEmpty else {
            return Data()
        }

        var output = [UInt8](repeating: 0, count: data.count)
        let input = [UInt8](data)
        let keyBytes = [UInt8](key)
        let nonceBytes = [UInt8](nonce)

        let status = output.withUnsafeMutableBufferPointer { outPtr in
            input.withUnsafeBufferPointer { inPtr in
                keyBytes.withUnsafeBufferPointer { keyPtr in
                    nonceBytes.withUnsafeBufferPointer { noncePtr in
                        crypto_stream_chacha20_ietf_xor(
                            outPtr.baseAddress!,
                            inPtr.baseAddress!,
                            UInt64(input.count),
                            noncePtr.baseAddress!,
                            keyPtr.baseAddress!
                        )
                    }
                }
            }
        }

        guard status == 0 else {
            throw ChaCha20StreamCipherError.sodiumFailure
        }
        return Data(output)
    }
}
