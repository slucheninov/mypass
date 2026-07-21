import XCTest
import CryptoKit
@testable import MyPassKit

final class HmacBlockStreamReaderTests: XCTestCase {
    func testReadsSingleBlockPlusFinalBlock() throws {
        let hmacKeyBase = Data(repeating: 0x42, count: 64)
        let payload = Data("hello kdbx4".utf8)

        var stream = Data()
        appendBlock(&stream, index: 0, data: payload, hmacKeyBase: hmacKeyBase)
        appendBlock(&stream, index: 1, data: Data(), hmacKeyBase: hmacKeyBase)

        let result = try HmacBlockStream.read(stream, hmacKeyBase: hmacKeyBase)
        XCTAssertEqual(result, payload)
    }

    func testConcatenatesMultipleBlocks() throws {
        let hmacKeyBase = Data(repeating: 0x77, count: 64)
        let first = Data("first block ".utf8)
        let second = Data("second block".utf8)

        var stream = Data()
        appendBlock(&stream, index: 0, data: first, hmacKeyBase: hmacKeyBase)
        appendBlock(&stream, index: 1, data: second, hmacKeyBase: hmacKeyBase)
        appendBlock(&stream, index: 2, data: Data(), hmacKeyBase: hmacKeyBase)

        let result = try HmacBlockStream.read(stream, hmacKeyBase: hmacKeyBase)
        XCTAssertEqual(result, first + second)
    }

    func testCorruptedBlockDataThrows() throws {
        let hmacKeyBase = Data(repeating: 0x42, count: 64)
        var stream = Data()
        appendBlock(&stream, index: 0, data: Data("original".utf8), hmacKeyBase: hmacKeyBase)
        appendBlock(&stream, index: 1, data: Data(), hmacKeyBase: hmacKeyBase)
        // Corrupt a data byte of the first block after computing the HMAC:
        stream[stream.startIndex.advanced(by: 32 + 4)] ^= 0xFF

        XCTAssertThrowsError(try HmacBlockStream.read(stream, hmacKeyBase: hmacKeyBase)) { error in
            guard case HmacBlockStreamError.hmacMismatch(let index) = error else {
                return XCTFail("expected hmacMismatch, got \(error)")
            }
            XCTAssertEqual(index, 0)
        }
    }

    func testCorruptedStoredMacThrows() throws {
        let hmacKeyBase = Data(repeating: 0x11, count: 64)
        var stream = Data()
        appendBlock(&stream, index: 0, data: Data("payload".utf8), hmacKeyBase: hmacKeyBase)
        appendBlock(&stream, index: 1, data: Data(), hmacKeyBase: hmacKeyBase)
        // Corrupt a byte of the stored HMAC itself:
        stream[stream.startIndex] ^= 0xFF

        XCTAssertThrowsError(try HmacBlockStream.read(stream, hmacKeyBase: hmacKeyBase)) { error in
            guard case HmacBlockStreamError.hmacMismatch(let index) = error else {
                return XCTFail("expected hmacMismatch, got \(error)")
            }
            XCTAssertEqual(index, 0)
        }
    }

    func testTruncatedStreamThrows() throws {
        let hmacKeyBase = Data(repeating: 0x99, count: 64)
        var stream = Data()
        appendBlock(&stream, index: 0, data: Data("payload".utf8), hmacKeyBase: hmacKeyBase)
        appendBlock(&stream, index: 1, data: Data(), hmacKeyBase: hmacKeyBase)
        // Truncate mid-stream, before the terminal block is fully readable.
        stream.removeLast(4)

        XCTAssertThrowsError(try HmacBlockStream.read(stream, hmacKeyBase: hmacKeyBase)) { error in
            guard case HmacBlockStreamError.truncated = error else {
                return XCTFail("expected truncated, got \(error)")
            }
        }
    }

    func testEmptyStreamThrowsTruncated() throws {
        let hmacKeyBase = Data(repeating: 0x33, count: 64)
        XCTAssertThrowsError(try HmacBlockStream.read(Data(), hmacKeyBase: hmacKeyBase)) { error in
            guard case HmacBlockStreamError.truncated = error else {
                return XCTFail("expected truncated, got \(error)")
            }
        }
    }
}

private func appendBlock(_ stream: inout Data, index: UInt64, data: Data, hmacKeyBase: Data) {
    let blockKey = HmacBlockStream.blockKey(index: index, hmacKeyBase: hmacKeyBase)
    var macInput = Data(withUnsafeBytes(of: index.littleEndian) { Data($0) })
    macInput.append(contentsOf: withUnsafeBytes(of: Int32(data.count).littleEndian) { Data($0) })
    macInput.append(data)
    let mac = HMAC<SHA256>.authenticationCode(for: macInput, using: SymmetricKey(data: blockKey))
    stream.append(Data(mac))
    stream.append(contentsOf: withUnsafeBytes(of: Int32(data.count).littleEndian) { Data($0) })
    stream.append(data)
}
