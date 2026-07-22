import Foundation
import CryptoKit

/// Errors raised while reading and verifying the KDBX4 HMAC block stream
/// that follows the outer header.
enum HmacBlockStreamError: Error, Equatable {
    /// The stream ended before a complete block (HMAC + size + data) could
    /// be read.
    case truncated
    /// The stored HMAC for the block at `blockIndex` did not match the
    /// HMAC computed over that block's index/size/data — the block (or the
    /// stored HMAC itself) has been tampered with or is corrupt.
    case hmacMismatch(blockIndex: UInt64)
}

extension HmacBlockStream {
    /// Reads the HMAC block stream: a sequence of
    /// `HMAC-SHA256(32 bytes) ‖ BlockSize(4 bytes, Int32 LE) ‖ BlockData`
    /// blocks, terminated by a zero-size block. Each block's HMAC is
    /// verified — keyed by `blockKey(index:hmacKeyBase:)` for that block's
    /// index, starting at 0 and incrementing by one per block including the
    /// terminal zero-size block — before its data is accepted.
    ///
    /// Returns the concatenation of all non-terminal blocks' data, with the
    /// block framing (HMAC + size prefixes) stripped.
    static func read(_ data: Data, hmacKeyBase: Data) throws -> Data {
        let macSize = 32
        let sizeFieldSize = 4
        var offset = data.startIndex
        var result = Data()
        var index: UInt64 = 0

        while true {
            guard data.distance(from: offset, to: data.endIndex) >= macSize + sizeFieldSize else {
                throw HmacBlockStreamError.truncated
            }
            let macEnd = data.index(offset, offsetBy: macSize)
            let storedMac = Data(data[offset..<macEnd])
            offset = macEnd

            let sizeEnd = data.index(offset, offsetBy: sizeFieldSize)
            let sizeField = data[offset..<sizeEnd]
            let blockSize = Int(sizeField.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }.littleEndian)
            offset = sizeEnd

            guard blockSize >= 0, data.distance(from: offset, to: data.endIndex) >= blockSize else {
                throw HmacBlockStreamError.truncated
            }
            let dataEnd = data.index(offset, offsetBy: blockSize)
            let blockData = Data(data[offset..<dataEnd])
            offset = dataEnd

            let blockKey = HmacBlockStream.blockKey(index: index, hmacKeyBase: hmacKeyBase)
            var macInput = Data(withUnsafeBytes(of: index.littleEndian) { Data($0) })
            macInput.append(contentsOf: withUnsafeBytes(of: Int32(blockSize).littleEndian) { Data($0) })
            macInput.append(blockData)
            let expectedMac = Data(HMAC<SHA256>.authenticationCode(for: macInput, using: SymmetricKey(data: blockKey)))

            guard expectedMac == storedMac else {
                throw HmacBlockStreamError.hmacMismatch(blockIndex: index)
            }

            if blockSize == 0 {
                return result
            }
            result.append(blockData)
            index += 1
        }
    }
}
