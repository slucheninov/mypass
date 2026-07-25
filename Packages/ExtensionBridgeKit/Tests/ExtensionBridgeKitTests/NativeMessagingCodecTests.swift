import XCTest
@testable import ExtensionBridgeKit

final class NativeMessagingCodecTests: XCTestCase {
    func testEncodePrependsFourByteLittleEndianLength() {
        let payload = Data("hi".utf8)
        let framed = NativeMessagingCodec.encode(payload)
        XCTAssertEqual(framed.count, 4 + payload.count)
        XCTAssertEqual(Array(framed.prefix(4)), [2, 0, 0, 0])
        XCTAssertEqual(framed.suffix(from: 4), payload)
    }

    func testFeedReturnsDecodedFrameWhenAllBytesArrivedAtOnce() throws {
        let payload = Data("hello".utf8)
        let framed = NativeMessagingCodec.encode(payload)
        let reader = NativeMessagingFrameReader()
        let frames = try reader.feed(framed)
        XCTAssertEqual(frames, [payload])
    }

    func testFeedAccumulatesAcrossMultiplePartialCalls() throws {
        let payload = Data("partial-frame-payload".utf8)
        let framed = NativeMessagingCodec.encode(payload)
        let reader = NativeMessagingFrameReader()

        let firstChunk = framed.prefix(3)
        let secondChunk = framed.subdata(in: 3..<10)
        let thirdChunk = framed.subdata(in: 10..<framed.count)

        XCTAssertEqual(try reader.feed(Data(firstChunk)), [])
        XCTAssertEqual(try reader.feed(secondChunk), [])
        XCTAssertEqual(try reader.feed(thirdChunk), [payload])
    }

    func testFeedReturnsMultipleFramesFromOneCall() throws {
        let first = Data("frame-one".utf8)
        let second = Data("frame-two".utf8)
        var combined = NativeMessagingCodec.encode(first)
        combined.append(NativeMessagingCodec.encode(second))

        let reader = NativeMessagingFrameReader()
        let frames = try reader.feed(combined)
        XCTAssertEqual(frames, [first, second])
    }

    func testEmptyPayloadRoundTrips() throws {
        let payload = Data()
        let framed = NativeMessagingCodec.encode(payload)
        let reader = NativeMessagingFrameReader()
        XCTAssertEqual(try reader.feed(framed), [payload])
    }

    func testFeedRejectsClaimedLengthAboveConfiguredMaxWithoutBufferingPayload() {
        // Configure a tiny cap so the test doesn't need to allocate a
        // multi-megabyte payload to exercise the guard. Only the 4-byte
        // length prefix is sent — if the reader buffered toward the claimed
        // length instead of rejecting immediately, this would hang/never
        // return frames rather than throw, since the payload never arrives.
        let reader = NativeMessagingFrameReader(maxFrameSize: 16)
        var oversizedLengthPrefix = UInt32(1_000_000).littleEndian
        let header = Data(bytes: &oversizedLengthPrefix, count: 4)

        XCTAssertThrowsError(try reader.feed(header)) { error in
            XCTAssertEqual(
                error as? NativeMessagingFrameReaderError,
                .frameTooLarge(claimed: 1_000_000, max: 16)
            )
        }
    }

    func testFeedAcceptsFrameExactlyAtConfiguredMax() throws {
        let reader = NativeMessagingFrameReader(maxFrameSize: 16)
        let payload = Data(repeating: 0x41, count: 16)
        let framed = NativeMessagingCodec.encode(payload)
        XCTAssertEqual(try reader.feed(framed), [payload])
    }
}
