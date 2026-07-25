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

    func testFeedReturnsDecodedFrameWhenAllBytesArrivedAtOnce() {
        let payload = Data("hello".utf8)
        let framed = NativeMessagingCodec.encode(payload)
        let reader = NativeMessagingFrameReader()
        let frames = reader.feed(framed)
        XCTAssertEqual(frames, [payload])
    }

    func testFeedAccumulatesAcrossMultiplePartialCalls() {
        let payload = Data("partial-frame-payload".utf8)
        let framed = NativeMessagingCodec.encode(payload)
        let reader = NativeMessagingFrameReader()

        let firstChunk = framed.prefix(3)
        let secondChunk = framed.subdata(in: 3..<10)
        let thirdChunk = framed.subdata(in: 10..<framed.count)

        XCTAssertEqual(reader.feed(Data(firstChunk)), [])
        XCTAssertEqual(reader.feed(secondChunk), [])
        XCTAssertEqual(reader.feed(thirdChunk), [payload])
    }

    func testFeedReturnsMultipleFramesFromOneCall() {
        let first = Data("frame-one".utf8)
        let second = Data("frame-two".utf8)
        var combined = NativeMessagingCodec.encode(first)
        combined.append(NativeMessagingCodec.encode(second))

        let reader = NativeMessagingFrameReader()
        let frames = reader.feed(combined)
        XCTAssertEqual(frames, [first, second])
    }

    func testEmptyPayloadRoundTrips() {
        let payload = Data()
        let framed = NativeMessagingCodec.encode(payload)
        let reader = NativeMessagingFrameReader()
        XCTAssertEqual(reader.feed(framed), [payload])
    }
}
