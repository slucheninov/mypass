import XCTest
@testable import MyPassKit

final class ChaCha20StreamCipherTests: XCTestCase {
    func testEncryptDecryptIsSymmetric() throws {
        let key = Data(repeating: 0x11, count: 32)
        let nonce = Data(repeating: 0x22, count: 12) // KDBX4 ChaCha20 IV = 12 bytes
        let plaintext = Data("MyPassKit ChaCha20 outer cipher test".utf8)

        let ciphertext = try ChaCha20StreamCipher.apply(to: plaintext, key: key, nonce: nonce)
        let roundTrip = try ChaCha20StreamCipher.apply(to: ciphertext, key: key, nonce: nonce)

        XCTAssertNotEqual(ciphertext, plaintext)
        XCTAssertEqual(roundTrip, plaintext)
    }

    func testDifferentNonceProducesDifferentCiphertext() throws {
        let key = Data(repeating: 0x33, count: 32)
        let plaintext = Data(repeating: 0x00, count: 64)
        let ciphertextA = try ChaCha20StreamCipher.apply(to: plaintext, key: key, nonce: Data(repeating: 0x01, count: 12))
        let ciphertextB = try ChaCha20StreamCipher.apply(to: plaintext, key: key, nonce: Data(repeating: 0x02, count: 12))
        XCTAssertNotEqual(ciphertextA, ciphertextB)
    }

    /// RFC 8439 §2.3.2 "Test Vector for the ChaCha20 Block Function":
    /// all-zero 32-byte key, all-zero 12-byte (IETF) nonce, block counter 0.
    /// XOR-ing the 64-byte all-zero plaintext with the keystream yields the
    /// keystream itself, so this independently verifies that
    /// `crypto_stream_chacha20_ietf_xor` (counter starts at 0) produces
    /// exactly the RFC's keystream bytes — i.e. the correct IETF variant.
    func testMatchesRFC8439BlockFunctionTestVector() throws {
        let key = Data(repeating: 0x00, count: 32)
        let nonce = Data(repeating: 0x00, count: 12)
        let plaintext = Data(repeating: 0x00, count: 64)

        let expectedKeystreamHex = """
        76b8e0ada0f13d90405d6ae55386bd28\
        bdd219b8a08ded1aa836efcc8b770dc7\
        da41597c5157488d7724e03fb8d84a37\
        6a43b8f41518a11cc387b669b2ee6586
        """
        let expected = Data(hexString: expectedKeystreamHex)

        let ciphertext = try ChaCha20StreamCipher.apply(to: plaintext, key: key, nonce: nonce)

        XCTAssertEqual(ciphertext, expected)
    }

    func testInvalidKeyLengthThrowsTypedError() {
        let shortKey = Data(repeating: 0x11, count: 16)
        let nonce = Data(repeating: 0x22, count: 12)
        XCTAssertThrowsError(try ChaCha20StreamCipher.apply(to: Data([0x00]), key: shortKey, nonce: nonce)) { error in
            XCTAssertEqual(error as? ChaCha20StreamCipherError, .invalidKeyOrNonceLength)
        }
    }

    func testInvalidNonceLengthThrowsTypedError() {
        let key = Data(repeating: 0x11, count: 32)
        let shortNonce = Data(repeating: 0x22, count: 8) // original Bernstein 8-byte nonce, not IETF
        XCTAssertThrowsError(try ChaCha20StreamCipher.apply(to: Data([0x00]), key: key, nonce: shortNonce)) { error in
            XCTAssertEqual(error as? ChaCha20StreamCipherError, .invalidKeyOrNonceLength)
        }
    }
}

private extension Data {
    init(hexString: String) {
        var data = Data(capacity: hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            let byteString = hexString[index..<next]
            data.append(UInt8(byteString, radix: 16)!)
            index = next
        }
        self = data
    }
}
