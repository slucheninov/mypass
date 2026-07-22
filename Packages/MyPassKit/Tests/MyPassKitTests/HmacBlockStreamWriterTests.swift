import XCTest
@testable import MyPassKit

final class HmacBlockStreamWriterTests: XCTestCase {
    func testWriteThenReadRoundTrip() throws {
        let hmacKeyBase = Data(repeating: 0x77, count: 64)
        let payload = Data((0..<5000).map { UInt8($0 % 256) })

        let written = HmacBlockStream.write(payload, hmacKeyBase: hmacKeyBase, blockSize: 1024)
        let readBack = try HmacBlockStream.read(written, hmacKeyBase: hmacKeyBase)

        XCTAssertEqual(readBack, payload)
    }

    func testEmptyPayloadProducesOnlyFinalBlock() throws {
        let hmacKeyBase = Data(repeating: 0x88, count: 64)
        let written = HmacBlockStream.write(Data(), hmacKeyBase: hmacKeyBase, blockSize: 1024)
        let readBack = try HmacBlockStream.read(written, hmacKeyBase: hmacKeyBase)
        XCTAssertEqual(readBack, Data())
    }

    func testDefaultBlockSizeIsOneMebibyte() {
        XCTAssertEqual(HmacBlockStream.defaultBlockSize, 1 << 20)
    }

    func testWriteWithDefaultBlockSizeRoundTrips() throws {
        let hmacKeyBase = Data(repeating: 0x11, count: 64)
        let payload = Data((0..<(2 * (1 << 20) + 123)).map { UInt8($0 % 256) })

        let written = HmacBlockStream.write(payload, hmacKeyBase: hmacKeyBase)
        let readBack = try HmacBlockStream.read(written, hmacKeyBase: hmacKeyBase)

        XCTAssertEqual(readBack, payload)
    }
}
