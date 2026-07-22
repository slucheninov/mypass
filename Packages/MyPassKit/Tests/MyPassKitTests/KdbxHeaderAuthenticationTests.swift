import XCTest
import CryptoKit
@testable import MyPassKit


final class KdbxHeaderAuthenticationTests: XCTestCase {
    func testSerializeThenParseRoundTrip() throws {
        var kdf = VariantDictionary()
        kdf.items["$UUID"] = .byteArray(KdbxKdfUUID.argon2id)
        kdf.items["M"] = .uint64(65536)

        let header = KdbxOuterHeader(
            cipher: .chaCha20,
            compression: .gzip,
            masterSeed: Data(repeating: 0x11, count: 32),
            encryptionIV: Data(repeating: 0x22, count: 12),
            kdfParameters: kdf,
            publicCustomData: nil,
            rawHeaderBytes: Data()
        )

        let serialized = header.serialize()
        var offset = serialized.startIndex
        let parsed = try KdbxOuterHeader.parse(from: serialized, startingAt: &offset)

        XCTAssertEqual(parsed.cipher, .chaCha20)
        XCTAssertEqual(parsed.compression, .gzip)
        XCTAssertEqual(parsed.masterSeed, header.masterSeed)
        XCTAssertEqual(parsed.encryptionIV, header.encryptionIV)
        XCTAssertEqual(offset, serialized.endIndex)
    }

    func testHeaderSHA256MatchesManualComputation() {
        let raw = Data([1, 2, 3, 4, 5])
        let expected = Data(SHA256.hash(data: raw))
        XCTAssertEqual(KdbxHeaderAuthentication.sha256(ofHeader: raw), expected)
    }

    func testHeaderHmacIsDeterministicAndKeyDependent() {
        let raw = Data([1, 2, 3, 4, 5])
        let keyA = Data(repeating: 0xAA, count: 64)
        let keyB = Data(repeating: 0xBB, count: 64)
        let hmacA1 = KdbxHeaderAuthentication.hmacSHA256(ofHeader: raw, hmacKeyBase: keyA)
        let hmacA2 = KdbxHeaderAuthentication.hmacSHA256(ofHeader: raw, hmacKeyBase: keyA)
        let hmacB = KdbxHeaderAuthentication.hmacSHA256(ofHeader: raw, hmacKeyBase: keyB)
        XCTAssertEqual(hmacA1, hmacA2)
        XCTAssertNotEqual(hmacA1, hmacB)
        XCTAssertEqual(hmacA1.count, 32)
    }
}
