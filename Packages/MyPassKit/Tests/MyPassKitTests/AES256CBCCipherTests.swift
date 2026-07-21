import XCTest
@testable import MyPassKit

final class AES256CBCCipherTests: XCTestCase {
    // NIST SP 800-38A F.2.5 CBC-AES256.Encrypt, первый блок.
    // Verified directly against the NIST PDF text (nvlpubs.nist.gov/nistpubs/legacy/sp/
    // nistspecialpublication800-38a.pdf), cross-checked against the identical key/plaintext
    // reused in F.1.5 (ECB-AES256.Encrypt) and F.5.5 (CTR-AES256.Encrypt) of the same document:
    // Key = 603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4
    // IV  = 000102030405060708090a0b0c0d0e0f
    // Plaintext block 1 = 6bc1bee22e409f96e93d7e117393172a
    // Ciphertext block 1 = f58c4c04d6e5f1ba779eabfb5f7bfbd6
    func testMatchesNistCbcVector() throws {
        let key = Data(hex: "603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4")
        let iv = Data(hex: "000102030405060708090a0b0c0d0e0f")
        let plaintextBlock = Data(hex: "6bc1bee22e409f96e93d7e117393172a")
        let expectedCiphertextBlock = Data(hex: "f58c4c04d6e5f1ba779eabfb5f7bfbd6")

        // NIST SP 800-38A's CBC test vectors are for the raw cipher operation
        // without any padding convention layered on top, so we exercise the
        // no-padding primitive here rather than the padded public `encrypt()`.
        let ciphertext = try AES256CBCCipher.encryptRawNoPadding(plaintext: plaintextBlock, key: key, iv: iv)
        XCTAssertEqual(ciphertext, expectedCiphertextBlock)
    }

    func testEncryptDecryptRoundTrip() throws {
        let key = Data(repeating: 0x5A, count: 32)
        let iv = Data(repeating: 0xA5, count: 16)
        let plaintext = Data("MyPassKit KDBX4 round-trip test payload, произвольная длина!".utf8)

        let ciphertext = try AES256CBCCipher.encrypt(plaintext: plaintext, key: key, iv: iv)
        let decrypted = try AES256CBCCipher.decrypt(ciphertext: ciphertext, key: key, iv: iv)

        XCTAssertEqual(decrypted, plaintext)
    }

    // Regression test for a defect where `encrypt()` skipped PKCS7 padding
    // whenever the plaintext length was an exact multiple of 16 bytes, while
    // `decrypt()` always assumed padding was present — silently corrupting
    // any block-aligned real-world payload (e.g. a KDBX4 XML blob that
    // happens to land on a 16-byte boundary) on round trip.
    func testEncryptDecryptRoundTripWithBlockAlignedPlaintext() throws {
        let key = Data(repeating: 0x3C, count: 32)
        let iv = Data(repeating: 0x7E, count: 16)
        let plaintext = Data(repeating: 0x42, count: 32) // exactly 2 AES blocks, no partial block

        let ciphertext = try AES256CBCCipher.encrypt(plaintext: plaintext, key: key, iv: iv)
        let decrypted = try AES256CBCCipher.decrypt(ciphertext: ciphertext, key: key, iv: iv)

        XCTAssertEqual(decrypted, plaintext)
    }

    func testInvalidKeyLengthThrows() {
        let key = Data(repeating: 0x01, count: 16) // AES-128 длина, не 256
        let iv = Data(repeating: 0x02, count: 16)
        XCTAssertThrowsError(try AES256CBCCipher.encrypt(plaintext: Data([1,2,3]), key: key, iv: iv)) { error in
            guard case CipherError.invalidKeyOrIVLength = error else {
                return XCTFail("expected invalidKeyOrIVLength, got \(error)")
            }
        }
    }
}

private extension Data {
    init(hex: String) {
        var data = Data()
        var chars = Array(hex)
        while chars.count >= 2 {
            let byteString = String(chars[0..<2])
            data.append(UInt8(byteString, radix: 16)!)
            chars.removeFirst(2)
        }
        self = data
    }
}
