import Foundation

/// 4-byte little-endian length prefix + raw JSON payload, matching Chrome's
/// native messaging framing (https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging).
/// Shared by both hops: ChromeHost <-> Chrome over stdio, and ChromeHost <-> MyPass.app over TCP.
public enum NativeMessagingCodec {
    public static func encode(_ payload: Data) -> Data {
        var length = UInt32(payload.count).littleEndian
        var framed = Data(bytes: &length, count: 4)
        framed.append(payload)
        return framed
    }
}

/// Thrown by `NativeMessagingFrameReader.feed` when a peer claims a frame
/// length larger than the reader's configured cap. The 4-byte length prefix
/// is an unchecked `UInt32` (up to ~4.29 GB); without a cap, a malicious or
/// buggy peer on a reachable socket (e.g. `LoopbackServer`, Task 6) could
/// force unbounded buffer growth in a password-manager process while the
/// reader waits for that many bytes to arrive. This protocol's actual JSON
/// payloads (credential lists, save proposals) are always tiny by comparison.
public enum NativeMessagingFrameReaderError: Error, Equatable {
    case frameTooLarge(claimed: Int, max: Int)
}

/// Incremental decoder: accumulates bytes fed via `feed(_:)` and returns zero or
/// more complete payloads, tolerating partial reads and multiple frames per call —
/// both are normal on a real stdio/TCP stream.
public final class NativeMessagingFrameReader {
    /// 10 MB is comfortably larger than any real payload this protocol ever
    /// sends (credential lists, save proposals — all small JSON), while still
    /// bounding worst-case memory growth from a hostile/buggy peer.
    public static let defaultMaxFrameSize = 10 * 1024 * 1024

    private var buffer = Data()
    private let maxFrameSize: Int

    public init(maxFrameSize: Int = NativeMessagingFrameReader.defaultMaxFrameSize) {
        self.maxFrameSize = maxFrameSize
    }

    /// - Throws: `NativeMessagingFrameReaderError.frameTooLarge` if the claimed
    ///   frame length exceeds `maxFrameSize`. The internal buffer is discarded
    ///   before throwing, so the reader never accumulates bytes toward an
    ///   oversized claimed length. Callers should treat this as fatal for the
    ///   connection (the byte stream can no longer be trusted to be
    ///   frame-aligned) rather than retriable.
    public func feed(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var frames: [Data] = []

        while buffer.count >= 4 {
            let lengthBytes = [UInt8](buffer.prefix(4))
            let length = UInt32(lengthBytes[0])
                | (UInt32(lengthBytes[1]) << 8)
                | (UInt32(lengthBytes[2]) << 16)
                | (UInt32(lengthBytes[3]) << 24)
            let frameLength = Int(length)

            guard frameLength <= maxFrameSize else {
                buffer.removeAll()
                throw NativeMessagingFrameReaderError.frameTooLarge(claimed: frameLength, max: maxFrameSize)
            }

            guard buffer.count >= 4 + frameLength else { break }

            let frame = buffer.subdata(in: 4..<(4 + frameLength))
            frames.append(frame)
            buffer.removeSubrange(0..<(4 + frameLength))
        }

        return frames
    }
}
