import Foundation

struct KdbxSignature: Equatable {}

enum KdbxHeaderError: Error, Equatable {
    case badSignature
    case unsupportedVersion(UInt16)
    case unknownCipher(Data)
    case unsupportedCompression(Int32)
    case missingRequiredField(UInt8)
    case truncated
}

extension KdbxSignature {
    /// Parses the 12-byte KDBX file signature and version.
    ///
    /// This reader only supports KDBX4 (major version == 4). Other major
    /// versions (e.g. KDBX3, major == 3) are rejected with
    /// `.unsupportedVersion`, since the outer-header field layout differs
    /// between major versions and this package targets KDBX4 exclusively.
    static func parse(_ data: Data) throws -> (signature: KdbxSignature, versionMajor: UInt16, versionMinor: UInt16, consumedBytes: Int) {
        guard data.count >= 12 else { throw KdbxHeaderError.truncated }

        var offset = data.startIndex

        func readBytes(_ count: Int) -> Data {
            let end = data.index(offset, offsetBy: count)
            let slice = Data(data[offset..<end])
            offset = end
            return slice
        }

        let sig1 = readBytes(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        let sig2 = readBytes(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        guard sig1 == 0x9AA2D903, sig2 == 0xB54BFB67 else {
            throw KdbxHeaderError.badSignature
        }

        let minor = readBytes(2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian
        let major = readBytes(2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian

        guard major == 4 else { throw KdbxHeaderError.unsupportedVersion(major) }

        return (KdbxSignature(), major, minor, data.distance(from: data.startIndex, to: offset))
    }
}
