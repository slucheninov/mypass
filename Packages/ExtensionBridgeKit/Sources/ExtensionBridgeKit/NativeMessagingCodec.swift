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

/// Incremental decoder: accumulates bytes fed via `feed(_:)` and returns zero or
/// more complete payloads, tolerating partial reads and multiple frames per call —
/// both are normal on a real stdio/TCP stream.
public final class NativeMessagingFrameReader {
    private var buffer = Data()

    public init() {}

    public func feed(_ data: Data) -> [Data] {
        buffer.append(data)
        var frames: [Data] = []

        while buffer.count >= 4 {
            let lengthBytes = [UInt8](buffer.prefix(4))
            let length = UInt32(lengthBytes[0])
                | (UInt32(lengthBytes[1]) << 8)
                | (UInt32(lengthBytes[2]) << 16)
                | (UInt32(lengthBytes[3]) << 24)
            let frameLength = Int(length)

            guard buffer.count >= 4 + frameLength else { break }

            let frame = buffer.subdata(in: 4..<(4 + frameLength))
            frames.append(frame)
            buffer.removeSubrange(0..<(4 + frameLength))
        }

        return frames
    }
}
