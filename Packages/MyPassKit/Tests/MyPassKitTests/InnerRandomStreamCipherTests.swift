import CryptoKit
import XCTest
@testable import MyPassKit

final class InnerRandomStreamCipherTests: XCTestCase {
    func testChaCha20StreamIsDeterministicAndSequential() throws {
        let rawKey = Data(repeating: 0x55, count: 64)
        let cipherA = try InnerRandomStreamCipher(streamID: .chaCha20, rawKey: rawKey)
        let firstCall = cipherA.nextBytes(8)
        let secondCall = cipherA.nextBytes(8)

        let cipherB = try InnerRandomStreamCipher(streamID: .chaCha20, rawKey: rawKey)
        let combinedCall = cipherB.nextBytes(16)

        XCTAssertEqual(firstCall + secondCall, combinedCall, "keystream must be continuous regardless of call splitting")
    }

    func testSalsa20StreamProducesNonTrivialOutput() throws {
        let rawKey = Data(repeating: 0x66, count: 32)
        let cipher = try InnerRandomStreamCipher(streamID: .salsa20, rawKey: rawKey)
        let keystream = cipher.nextBytes(32)
        XCTAssertNotEqual(keystream, Data(repeating: 0, count: 32))
    }

    func testSalsa20StreamIsDeterministicAndSequential() throws {
        let rawKey = Data(repeating: 0x66, count: 32)
        let cipherA = try InnerRandomStreamCipher(streamID: .salsa20, rawKey: rawKey)
        let firstCall = cipherA.nextBytes(10)
        let secondCall = cipherA.nextBytes(70)

        let cipherB = try InnerRandomStreamCipher(streamID: .salsa20, rawKey: rawKey)
        let combinedCall = cipherB.nextBytes(80)

        XCTAssertEqual(firstCall + secondCall, combinedCall, "Salsa20 keystream must be continuous across 64-byte block boundaries")
    }

    func testXorRoundTripThroughProtectedValue() throws {
        let rawKey = Data(repeating: 0x77, count: 64)
        let plaintext = Data("secret-password-value".utf8)

        let encryptCipher = try InnerRandomStreamCipher(streamID: .chaCha20, rawKey: rawKey)
        let keystream = encryptCipher.nextBytes(plaintext.count)
        let obfuscated = xor(plaintext, keystream)

        let decryptCipher = try InnerRandomStreamCipher(streamID: .chaCha20, rawKey: rawKey)
        let keystream2 = decryptCipher.nextBytes(obfuscated.count)
        let recovered = xor(obfuscated, keystream2)

        XCTAssertEqual(recovered, plaintext)
    }

    func testArcFourVariantIsUnsupported() throws {
        let rawKey = Data(repeating: 0x11, count: 32)
        XCTAssertThrowsError(try InnerRandomStreamCipher(streamID: .arcFourVariant, rawKey: rawKey)) { error in
            guard let cipherError = error as? InnerRandomStreamCipherError else {
                XCTFail("Unexpected error type: \(error)")
                return
            }
            XCTAssertEqual(cipherError, .unsupportedStream(1))
        }
    }

    /// Cross-checks the ChaCha20 keystream against libsodium's raw
    /// `crypto_stream_chacha20_ietf` primitive computed independently with the
    /// exact key-derivation KeePassXC uses (SHA512(rawKey) split key‖nonce),
    /// so this test would fail if the split boundaries were wrong.
    func testChaCha20MatchesIndependentlyComputedKeystream() throws {
        let rawKey = Data(repeating: 0x99, count: 40)
        let hashed = Data(SHA512.hash(data: rawKey))
        let key = hashed.subdata(in: 0..<32)
        let nonce = hashed.subdata(in: 32..<44)

        let expected = try ChaCha20StreamCipher.apply(to: Data(repeating: 0, count: 32), key: key, nonce: nonce)

        let cipher = try InnerRandomStreamCipher(streamID: .chaCha20, rawKey: rawKey)
        let actual = cipher.nextBytes(32)

        XCTAssertEqual(actual, expected)
    }
}

private func xor(_ a: Data, _ b: Data) -> Data {
    Data(zip(a, b).map { $0 ^ $1 })
}
