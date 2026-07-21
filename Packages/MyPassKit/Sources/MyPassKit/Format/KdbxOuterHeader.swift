import Foundation

enum KdbxCipher: Equatable {
    case aes256
    case chaCha20

    static let aes256UUID = Data([0x31, 0xC1, 0xF2, 0xE6, 0xBF, 0x71, 0x43, 0x50,
                                   0xBE, 0x58, 0x05, 0x21, 0x6A, 0xFC, 0x5A, 0xFF])
    static let chaCha20UUID = Data([0xD6, 0x03, 0x8A, 0x2B, 0x8B, 0x6F, 0x4C, 0xB5,
                                     0xA5, 0x24, 0x33, 0x9A, 0x31, 0xDB, 0xB5, 0x9A])

    static func from(uuid: Data) throws -> KdbxCipher {
        switch uuid {
        case aes256UUID: return .aes256
        case chaCha20UUID: return .chaCha20
        default: throw KdbxHeaderError.unknownCipher(uuid)
        }
    }
}

enum KdbxCompression: Equatable { case none, gzip }

/// Field IDs for the KDBX4 outer header TLV stream.
private enum KdbxHeaderFieldID {
    static let endOfHeader: UInt8 = 0
    static let comment: UInt8 = 1
    static let cipherID: UInt8 = 2
    static let compressionFlags: UInt8 = 3
    static let masterSeed: UInt8 = 4
    // Obsolete-in-KDBX4 fields, retained from KDBX3. Readers must tolerate
    // (ignore) these if present rather than reject the file, since some
    // KDBX4 files produced by older/lenient writers may still carry them.
    static let transformSeed: UInt8 = 5
    static let transformRounds: UInt8 = 6
    static let encryptionIV: UInt8 = 7
    static let protectedStreamKey: UInt8 = 8
    static let streamStartBytes: UInt8 = 9
    static let innerRandomStreamID: UInt8 = 10
    static let kdfParameters: UInt8 = 11
    static let publicCustomData: UInt8 = 12
}

struct KdbxOuterHeader: Equatable {
    var cipher: KdbxCipher
    var compression: KdbxCompression
    var masterSeed: Data
    var encryptionIV: Data
    var kdfParameters: VariantDictionary
    var publicCustomData: VariantDictionary?
    /// The raw bytes of the outer header exactly as they appeared in the
    /// file, spanning from the first TLV field through and including the
    /// EndOfHeader (ID=0) field itself. This is what KDBX4's SHA-256/HMAC
    /// header verification (Task 7) is computed over.
    var rawHeaderBytes: Data

    static func parse(from data: Data, startingAt offset: inout Data.Index) throws -> KdbxOuterHeader {
        let headerStart = offset
        var cipher: KdbxCipher?
        var compression: KdbxCompression?
        var masterSeed: Data?
        var encryptionIV: Data?
        var kdfParameters: VariantDictionary?
        var publicCustomData: VariantDictionary?

        while true {
            // Need at least 1 byte (field ID) + 4 bytes (Int32 length) before reading a value.
            guard data.distance(from: offset, to: data.endIndex) >= 5 else {
                throw KdbxHeaderError.truncated
            }
            let id = data[offset]
            offset = data.index(after: offset)

            let lengthEnd = data.index(offset, offsetBy: 4)
            let lengthBytes = Data(data[offset..<lengthEnd])
            let length = Int(lengthBytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }.littleEndian)
            offset = lengthEnd

            guard length >= 0, data.distance(from: offset, to: data.endIndex) >= length else {
                throw KdbxHeaderError.truncated
            }
            let valueEnd = data.index(offset, offsetBy: length)
            let fieldData = Data(data[offset..<valueEnd])
            offset = valueEnd

            switch id {
            case KdbxHeaderFieldID.endOfHeader:
                let rawHeaderBytes = Data(data[headerStart..<offset])
                guard let cipher, let masterSeed, let encryptionIV, let kdfParameters else {
                    throw KdbxHeaderError.missingRequiredField(KdbxHeaderFieldID.cipherID)
                }
                return KdbxOuterHeader(
                    cipher: cipher,
                    compression: compression ?? .none,
                    masterSeed: masterSeed,
                    encryptionIV: encryptionIV,
                    kdfParameters: kdfParameters,
                    publicCustomData: publicCustomData,
                    rawHeaderBytes: rawHeaderBytes
                )
            case KdbxHeaderFieldID.cipherID:
                cipher = try KdbxCipher.from(uuid: fieldData)
            case KdbxHeaderFieldID.compressionFlags:
                guard fieldData.count == 4 else { throw KdbxHeaderError.truncated }
                let flag = fieldData.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }.littleEndian
                switch flag {
                case 0: compression = KdbxCompression.none
                case 1: compression = .gzip
                default: throw KdbxHeaderError.unsupportedCompression(flag)
                }
            case KdbxHeaderFieldID.masterSeed:
                masterSeed = fieldData
            case KdbxHeaderFieldID.encryptionIV:
                encryptionIV = fieldData
            case KdbxHeaderFieldID.kdfParameters:
                kdfParameters = try VariantDictionary.decode(fieldData)
            case KdbxHeaderFieldID.publicCustomData:
                publicCustomData = try VariantDictionary.decode(fieldData)
            case KdbxHeaderFieldID.comment,
                 KdbxHeaderFieldID.transformSeed,
                 KdbxHeaderFieldID.transformRounds,
                 KdbxHeaderFieldID.protectedStreamKey,
                 KdbxHeaderFieldID.streamStartBytes,
                 KdbxHeaderFieldID.innerRandomStreamID:
                break // Obsolete-in-KDBX4 / informational fields — ignored on read.
            default:
                break // Unknown field ID — ignored for forward compatibility.
            }
        }
    }
}
