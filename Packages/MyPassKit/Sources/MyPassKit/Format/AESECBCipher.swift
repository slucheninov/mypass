import Foundation
import CommonCrypto

enum AESECBCipherError: Error, Equatable {
    case invalidKeyLength
    case invalidDataLength
    case operationFailed
}

/// Raw AES-256-ECB block cipher, iterated in place. Used exclusively by
/// AES-KDF (`KeyDerivation`'s `aesKdf` case) to reproduce KeePassXC's
/// classic key-transformation KDF for reading legacy KDBX4 files that opt
/// out of Argon2id.
///
/// Verified against KeePassXC's `src/crypto/SymmetricCipher.cpp`,
/// `SymmetricCipher::aesKdf()`:
/// ```cpp
/// bool SymmetricCipher::aesKdf(const QByteArray& key, int rounds, QByteArray& data)
/// {
///     std::unique_ptr<Botan::BlockCipher> cipher(Botan::BlockCipher::create("AES-256"));
///     cipher->set_key(reinterpret_cast<const uint8_t*>(key.data()), key.size());
///     Botan::secure_vector<uint8_t> out(data.begin(), data.end());
///     for (int i = 0; i < rounds; ++i) {
///         cipher->encrypt(out);
///     }
///     std::copy(out.begin(), out.end(), data.begin());
///     return true;
/// }
/// ```
/// `data` is the 32-byte composite key (2 AES blocks); `Botan::BlockCipher::
/// encrypt()` applied to a buffer spanning multiple blocks encrypts each
/// block independently with no chaining — i.e. plain AES-256-ECB, no
/// padding, keyed by the KDF's `S` seed, iterated `rounds` (`R`) times, with
/// each round's output fed back in as the next round's input. This is a
/// fundamentally different mode from `AES256CBCCipher` (which chains blocks
/// via an IV) and MUST NOT be substituted for it — CBC would silently
/// produce a self-consistent but wrong key.
///
/// Note: ECB mode is used here only because it is what the KDBX4/KeePassXC
/// AES-KDF specification mandates for this specific key-stretching
/// construction (encrypting the fixed-size composite key with a
/// caller-controlled seed, then hashing the result) — it is not used for
/// bulk plaintext encryption, where ECB's block-pattern leakage would be a
/// real concern. `AES256CBCCipher` remains the cipher for actual database
/// content.
enum AESECBCipher {
    /// Encrypts `data` (must be a non-empty whole multiple of the AES block
    /// size, 16 bytes — AES-KDF always calls this with the 32-byte
    /// composite key) with `key` (32 bytes, AES-256) `rounds` times.
    static func transform(data: Data, key: Data, rounds: UInt64) throws -> Data {
        guard key.count == kCCKeySizeAES256 else {
            throw AESECBCipherError.invalidKeyLength
        }
        guard !data.isEmpty, data.count % kCCBlockSizeAES128 == 0 else {
            throw AESECBCipherError.invalidDataLength
        }

        var cryptorRef: CCCryptorRef?
        let createStatus = key.withUnsafeBytes { keyPtr in
            CCCryptorCreateWithMode(
                CCOperation(kCCEncrypt),
                CCMode(kCCModeECB),
                CCAlgorithm(kCCAlgorithmAES),
                CCPadding(ccNoPadding),
                nil, // no IV — ECB has no chaining
                keyPtr.baseAddress, key.count,
                nil, 0, // no tweak (not a tweakable cipher mode)
                0, // default underlying rounds for AES itself, not AES-KDF's `R`
                CCModeOptions(0),
                &cryptorRef
            )
        }
        guard createStatus == kCCSuccess, let cryptor = cryptorRef else {
            throw AESECBCipherError.operationFailed
        }
        defer { CCCryptorRelease(cryptor) }

        var buffer = [UInt8](data)
        let bufferCount = buffer.count
        for _ in 0..<rounds {
            var moved = 0
            var outBuffer = [UInt8](repeating: 0, count: bufferCount)
            let status = outBuffer.withUnsafeMutableBytes { outPtr in
                buffer.withUnsafeBytes { inPtr in
                    CCCryptorUpdate(cryptor, inPtr.baseAddress, bufferCount, outPtr.baseAddress, bufferCount, &moved)
                }
            }
            guard status == kCCSuccess, moved == bufferCount else {
                throw AESECBCipherError.operationFailed
            }
            buffer = outBuffer
        }
        return Data(buffer)
    }
}
