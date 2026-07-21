import Foundation
import CryptoKit

extension HmacBlockStream {
    /// Default block size for the HMAC block stream: 1 MiB (2^20 bytes),
    /// per the KDBX4 format's global constraints.
    static let defaultBlockSize = 1 << 20

    /// Writes `payload` as a KDBX4 HMAC block stream: a sequence of
    /// `HMAC-SHA256(32 bytes) ‖ BlockSize(4 bytes, Int32 LE) ‖ BlockData`
    /// blocks, each `blockSize` bytes of payload (the last block shorter,
    /// not padded), terminated by a zero-size block. Each block's HMAC is
    /// keyed by `blockKey(index:hmacKeyBase:)` for that block's index,
    /// starting at 0 and incrementing by one per block including the
    /// terminal zero-size block — mirroring `HmacBlockStream.read`.
    static func write(_ payload: Data, hmacKeyBase: Data, blockSize: Int = defaultBlockSize) -> Data {
        var out = Data()
        var offset = payload.startIndex
        var index: UInt64 = 0

        func appendBlock(index: UInt64, data: Data) {
            let blockKey = HmacBlockStream.blockKey(index: index, hmacKeyBase: hmacKeyBase)
            var macInput = Data(withUnsafeBytes(of: index.littleEndian) { Data($0) })
            macInput.append(contentsOf: withUnsafeBytes(of: Int32(data.count).littleEndian) { Data($0) })
            macInput.append(data)
            let mac = HMAC<SHA256>.authenticationCode(for: macInput, using: SymmetricKey(data: blockKey))
            out.append(Data(mac))
            out.append(contentsOf: withUnsafeBytes(of: Int32(data.count).littleEndian) { Data($0) })
            out.append(data)
        }

        while offset < payload.endIndex {
            let end = payload.index(offset, offsetBy: blockSize, limitedBy: payload.endIndex) ?? payload.endIndex
            appendBlock(index: index, data: Data(payload[offset..<end]))
            offset = end
            index += 1
        }
        appendBlock(index: index, data: Data()) // terminal zero-size block
        return out
    }
}
