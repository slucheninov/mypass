import XCTest
@testable import MyPassKit

final class KdbxOuterHeaderTests: XCTestCase {
    func testParsesSignatureAndVersion() throws {
        var data = Data()
        data.append(contentsOf: withUnsafeBytes(of: UInt32(0x9AA2D903).littleEndian) { Data($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(0xB54BFB67).littleEndian) { Data($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(0x0000).littleEndian) { Data($0) }) // minor
        data.append(contentsOf: withUnsafeBytes(of: UInt16(0x0004).littleEndian) { Data($0) }) // major

        let (sig, major, minor, consumed) = try KdbxSignature.parse(data)
        XCTAssertEqual(sig, KdbxSignature())
        XCTAssertEqual(major, 4)
        XCTAssertEqual(minor, 0)
        XCTAssertEqual(consumed, 12)
    }

    func testBadSignatureThrows() {
        let data = Data([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11])
        XCTAssertThrowsError(try KdbxSignature.parse(data)) { error in
            guard case KdbxHeaderError.badSignature = error else {
                return XCTFail("expected badSignature, got \(error)")
            }
        }
    }

    func testUnsupportedVersionThrows() {
        var data = Data()
        data.append(contentsOf: withUnsafeBytes(of: UInt32(0x9AA2D903).littleEndian) { Data($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(0xB54BFB67).littleEndian) { Data($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(0x0000).littleEndian) { Data($0) }) // minor
        data.append(contentsOf: withUnsafeBytes(of: UInt16(0x0003).littleEndian) { Data($0) }) // major = 3 (KDBX3, unsupported)

        XCTAssertThrowsError(try KdbxSignature.parse(data)) { error in
            guard case KdbxHeaderError.unsupportedVersion(let major) = error else {
                return XCTFail("expected unsupportedVersion, got \(error)")
            }
            XCTAssertEqual(major, 3)
        }
    }

    func testSignatureTruncatedThrows() {
        let data = Data([0, 1, 2, 3])
        XCTAssertThrowsError(try KdbxSignature.parse(data)) { error in
            guard case KdbxHeaderError.truncated = error else {
                return XCTFail("expected truncated, got \(error)")
            }
        }
    }

    func testParsesMinimalOuterHeader() throws {
        var body = Data()
        // CipherID (2): AES256 UUID
        let aesUUID = Data([0x31, 0xC1, 0xF2, 0xE6, 0xBF, 0x71, 0x43, 0x50,
                             0xBE, 0x58, 0x05, 0x21, 0x6A, 0xFC, 0x5A, 0xFF])
        appendField(&body, id: 2, value: aesUUID)
        // CompressionFlags (3): GZip = 1
        appendField(&body, id: 3, value: withUnsafeBytes(of: Int32(1).littleEndian) { Data($0) })
        // MasterSeed (4): 32 bytes
        appendField(&body, id: 4, value: Data(repeating: 0xAB, count: 32))
        // EncryptionIV (7): 16 bytes for AES-CBC
        appendField(&body, id: 7, value: Data(repeating: 0xCD, count: 16))
        // KdfParameters (11): minimal VariantDictionary with Argon2id UUID
        var kdf = VariantDictionary()
        kdf.items["$UUID"] = .byteArray(Data([0x9e, 0x29, 0x8b, 0x19, 0x56, 0xdb, 0x47, 0x73,
                                               0xb2, 0x3d, 0xfc, 0x3e, 0xc6, 0xf0, 0xa1, 0xe6]))
        appendField(&body, id: 11, value: kdf.encode())
        // EndOfHeader (0)
        appendField(&body, id: 0, value: Data([0x0D, 0x0A, 0x0D, 0x0A]))

        var offset = body.startIndex
        let header = try KdbxOuterHeader.parse(from: body, startingAt: &offset)

        XCTAssertEqual(header.cipher, .aes256)
        XCTAssertEqual(header.compression, .gzip)
        XCTAssertEqual(header.masterSeed, Data(repeating: 0xAB, count: 32))
        XCTAssertEqual(header.encryptionIV, Data(repeating: 0xCD, count: 16))
        XCTAssertEqual(offset, body.endIndex)
        // rawHeaderBytes must cover the entire header INCLUDING the EndOfHeader TLV,
        // since that's what's hashed/HMAC'd in the real KDBX4 format.
        XCTAssertEqual(header.rawHeaderBytes, body)
    }

    func testChaCha20CipherRecognized() throws {
        var body = Data()
        let chaChaUUID = Data([0xD6, 0x03, 0x8A, 0x2B, 0x8B, 0x6F, 0x4C, 0xB5,
                                0xA5, 0x24, 0x33, 0x9A, 0x31, 0xDB, 0xB5, 0x9A])
        appendField(&body, id: 2, value: chaChaUUID)
        appendField(&body, id: 3, value: withUnsafeBytes(of: Int32(0).littleEndian) { Data($0) })
        appendField(&body, id: 4, value: Data(repeating: 0xAB, count: 32))
        appendField(&body, id: 7, value: Data(repeating: 0xCD, count: 12))
        var kdf = VariantDictionary()
        kdf.items["$UUID"] = .byteArray(Data([0x9e, 0x29, 0x8b, 0x19, 0x56, 0xdb, 0x47, 0x73,
                                               0xb2, 0x3d, 0xfc, 0x3e, 0xc6, 0xf0, 0xa1, 0xe6]))
        appendField(&body, id: 11, value: kdf.encode())
        appendField(&body, id: 0, value: Data([0x0D, 0x0A, 0x0D, 0x0A]))

        var offset = body.startIndex
        let header = try KdbxOuterHeader.parse(from: body, startingAt: &offset)
        XCTAssertEqual(header.cipher, .chaCha20)
        XCTAssertEqual(header.compression, .none)
    }

    func testUnknownFieldIsIgnored() throws {
        var body = Data()
        let aesUUID = Data([0x31, 0xC1, 0xF2, 0xE6, 0xBF, 0x71, 0x43, 0x50,
                             0xBE, 0x58, 0x05, 0x21, 0x6A, 0xFC, 0x5A, 0xFF])
        // Unknown field ID (e.g. 200) appearing before required fields — must be ignored, not crash.
        appendField(&body, id: 200, value: Data([0xFF, 0xFF]))
        appendField(&body, id: 2, value: aesUUID)
        appendField(&body, id: 3, value: withUnsafeBytes(of: Int32(0).littleEndian) { Data($0) })
        appendField(&body, id: 4, value: Data(repeating: 0xAB, count: 32))
        appendField(&body, id: 7, value: Data(repeating: 0xCD, count: 16))
        var kdf = VariantDictionary()
        kdf.items["$UUID"] = .byteArray(Data([0x9e, 0x29, 0x8b, 0x19, 0x56, 0xdb, 0x47, 0x73,
                                               0xb2, 0x3d, 0xfc, 0x3e, 0xc6, 0xf0, 0xa1, 0xe6]))
        appendField(&body, id: 11, value: kdf.encode())
        appendField(&body, id: 0, value: Data([0x0D, 0x0A, 0x0D, 0x0A]))

        var offset = body.startIndex
        let header = try KdbxOuterHeader.parse(from: body, startingAt: &offset)
        XCTAssertEqual(header.cipher, .aes256)
    }

    func testObsoleteKdbx3FieldsAreIgnored() throws {
        var body = Data()
        let aesUUID = Data([0x31, 0xC1, 0xF2, 0xE6, 0xBF, 0x71, 0x43, 0x50,
                             0xBE, 0x58, 0x05, 0x21, 0x6A, 0xFC, 0x5A, 0xFF])
        appendField(&body, id: 2, value: aesUUID)
        appendField(&body, id: 3, value: withUnsafeBytes(of: Int32(0).littleEndian) { Data($0) })
        appendField(&body, id: 4, value: Data(repeating: 0xAB, count: 32))
        // Obsolete KDBX3 fields: TransformSeed(5), TransformRounds(6), ProtectedStreamKey(8),
        // StreamStartBytes(9), InnerRandomStreamID(10) — must be tolerated/ignored, not rejected.
        appendField(&body, id: 5, value: Data(repeating: 0x01, count: 32))
        appendField(&body, id: 6, value: withUnsafeBytes(of: Int64(6000).littleEndian) { Data($0) })
        appendField(&body, id: 7, value: Data(repeating: 0xCD, count: 16))
        appendField(&body, id: 8, value: Data(repeating: 0x02, count: 32))
        appendField(&body, id: 9, value: Data(repeating: 0x03, count: 32))
        appendField(&body, id: 10, value: withUnsafeBytes(of: Int32(2).littleEndian) { Data($0) })
        var kdf = VariantDictionary()
        kdf.items["$UUID"] = .byteArray(Data([0x9e, 0x29, 0x8b, 0x19, 0x56, 0xdb, 0x47, 0x73,
                                               0xb2, 0x3d, 0xfc, 0x3e, 0xc6, 0xf0, 0xa1, 0xe6]))
        appendField(&body, id: 11, value: kdf.encode())
        appendField(&body, id: 0, value: Data([0x0D, 0x0A, 0x0D, 0x0A]))

        var offset = body.startIndex
        let header = try KdbxOuterHeader.parse(from: body, startingAt: &offset)
        XCTAssertEqual(header.cipher, .aes256)
        XCTAssertEqual(header.masterSeed, Data(repeating: 0xAB, count: 32))
        XCTAssertEqual(offset, body.endIndex)
    }

    func testPublicCustomDataIsParsed() throws {
        var body = Data()
        let aesUUID = Data([0x31, 0xC1, 0xF2, 0xE6, 0xBF, 0x71, 0x43, 0x50,
                             0xBE, 0x58, 0x05, 0x21, 0x6A, 0xFC, 0x5A, 0xFF])
        appendField(&body, id: 2, value: aesUUID)
        appendField(&body, id: 3, value: withUnsafeBytes(of: Int32(0).littleEndian) { Data($0) })
        appendField(&body, id: 4, value: Data(repeating: 0xAB, count: 32))
        appendField(&body, id: 7, value: Data(repeating: 0xCD, count: 16))
        var kdf = VariantDictionary()
        kdf.items["$UUID"] = .byteArray(Data([0x9e, 0x29, 0x8b, 0x19, 0x56, 0xdb, 0x47, 0x73,
                                               0xb2, 0x3d, 0xfc, 0x3e, 0xc6, 0xf0, 0xa1, 0xe6]))
        appendField(&body, id: 11, value: kdf.encode())
        var custom = VariantDictionary()
        custom.items["testKey"] = .string("testValue")
        appendField(&body, id: 12, value: custom.encode())
        appendField(&body, id: 0, value: Data([0x0D, 0x0A, 0x0D, 0x0A]))

        var offset = body.startIndex
        let header = try KdbxOuterHeader.parse(from: body, startingAt: &offset)
        XCTAssertEqual(header.publicCustomData?.items["testKey"], VariantValue.string("testValue"))
    }

    func testTruncatedOuterHeaderThrows() {
        var body = Data()
        let aesUUID = Data([0x31, 0xC1, 0xF2, 0xE6, 0xBF, 0x71, 0x43, 0x50,
                             0xBE, 0x58, 0x05, 0x21, 0x6A, 0xFC, 0x5A, 0xFF])
        appendField(&body, id: 2, value: aesUUID)
        appendField(&body, id: 4, value: Data(repeating: 0xAB, count: 32))
        // Truncate mid-way through the file — no EndOfHeader field, no more bytes.
        body.removeLast(4)

        var offset = body.startIndex
        XCTAssertThrowsError(try KdbxOuterHeader.parse(from: body, startingAt: &offset)) { error in
            guard case KdbxHeaderError.truncated = error else {
                return XCTFail("expected truncated, got \(error)")
            }
        }
    }

    func testMissingRequiredFieldThrows() {
        var body = Data()
        // Only MasterSeed provided; cipher, encryptionIV, kdfParameters are missing.
        appendField(&body, id: 4, value: Data(repeating: 0xAB, count: 32))
        appendField(&body, id: 0, value: Data([0x0D, 0x0A, 0x0D, 0x0A]))

        var offset = body.startIndex
        XCTAssertThrowsError(try KdbxOuterHeader.parse(from: body, startingAt: &offset)) { error in
            guard case KdbxHeaderError.missingRequiredField = error else {
                return XCTFail("expected missingRequiredField, got \(error)")
            }
        }
    }
}

private func appendField(_ data: inout Data, id: UInt8, value: Data) {
    data.append(id)
    data.append(contentsOf: withUnsafeBytes(of: Int32(value.count).littleEndian) { Data($0) })
    data.append(value)
}
