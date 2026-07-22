import XCTest
@testable import MyPassKit

final class KdbxInnerHeaderTests: XCTestCase {
    func testSerializeThenParseRoundTrip() throws {
        let header = KdbxInnerHeader(
            innerRandomStreamID: .chaCha20,
            innerRandomStreamKey: Data(repeating: 0x9A, count: 64),
            binaries: [
                KdbxInnerBinary(isProtected: false, content: Data("attachment-1".utf8)),
                KdbxInnerBinary(isProtected: true, content: Data("attachment-2-protected".utf8))
            ]
        )
        let serialized = header.serialize()
        var offset = serialized.startIndex
        let parsed = try KdbxInnerHeader.parse(from: serialized, startingAt: &offset)

        XCTAssertEqual(parsed, header)
        XCTAssertEqual(offset, serialized.endIndex)
    }

    func testMissingStreamKeyThrows() {
        var data = Data()
        data.append(1) // InnerRandomStreamID
        data.append(contentsOf: withUnsafeBytes(of: Int32(4).littleEndian) { Data($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(3).littleEndian) { Data($0) }) // ChaCha20
        data.append(0) // End
        data.append(contentsOf: withUnsafeBytes(of: Int32(0).littleEndian) { Data($0) })

        var offset = data.startIndex
        XCTAssertThrowsError(try KdbxInnerHeader.parse(from: data, startingAt: &offset)) { error in
            guard case KdbxInnerHeaderError.missingRequiredField = error else {
                return XCTFail("expected missingRequiredField, got \(error)")
            }
        }
    }

    func testUnknownStreamIDThrows() {
        var data = Data()
        data.append(1) // InnerRandomStreamID
        data.append(contentsOf: withUnsafeBytes(of: Int32(4).littleEndian) { Data($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(99).littleEndian) { Data($0) }) // unknown

        var offset = data.startIndex
        XCTAssertThrowsError(try KdbxInnerHeader.parse(from: data, startingAt: &offset)) { error in
            guard case KdbxInnerHeaderError.unknownStreamID(99) = error else {
                return XCTFail("expected unknownStreamID(99), got \(error)")
            }
        }
    }

    func testTruncatedDataThrows() {
        // Field header claims a length longer than the remaining bytes.
        var data = Data()
        data.append(1) // InnerRandomStreamID
        data.append(contentsOf: withUnsafeBytes(of: Int32(100).littleEndian) { Data($0) })
        data.append(contentsOf: [0x01, 0x02]) // only 2 bytes present, not 100

        var offset = data.startIndex
        XCTAssertThrowsError(try KdbxInnerHeader.parse(from: data, startingAt: &offset)) { error in
            guard case KdbxInnerHeaderError.truncated = error else {
                return XCTFail("expected truncated, got \(error)")
            }
        }
    }

    func testParseStopsAtEndFieldLeavingXMLPayloadUntouched() throws {
        let header = KdbxInnerHeader(
            innerRandomStreamID: .salsa20,
            innerRandomStreamKey: Data([0x01, 0x02, 0x03]),
            binaries: []
        )
        var data = header.serialize()
        let xmlPayload = Data("<KeePassFile></KeePassFile>".utf8)
        data.append(xmlPayload)

        var offset = data.startIndex
        let parsed = try KdbxInnerHeader.parse(from: data, startingAt: &offset)
        XCTAssertEqual(parsed, header)
        XCTAssertEqual(data[offset...], xmlPayload)
    }

    func testUnknownFieldIDIsIgnored() throws {
        var data = Data()
        // Unknown field ID 42 with some payload, should be skipped.
        data.append(42)
        data.append(contentsOf: withUnsafeBytes(of: Int32(3).littleEndian) { Data($0) })
        data.append(contentsOf: [0xAA, 0xBB, 0xCC])
        // Required fields.
        data.append(1)
        data.append(contentsOf: withUnsafeBytes(of: Int32(4).littleEndian) { Data($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(2).littleEndian) { Data($0) }) // Salsa20
        data.append(2)
        let key = Data([0x11, 0x22])
        data.append(contentsOf: withUnsafeBytes(of: Int32(key.count).littleEndian) { Data($0) })
        data.append(key)
        data.append(0)
        data.append(contentsOf: withUnsafeBytes(of: Int32(0).littleEndian) { Data($0) })

        var offset = data.startIndex
        let parsed = try KdbxInnerHeader.parse(from: data, startingAt: &offset)
        XCTAssertEqual(parsed.innerRandomStreamID, .salsa20)
        XCTAssertEqual(parsed.innerRandomStreamKey, key)
        XCTAssertEqual(offset, data.endIndex)
    }
}
