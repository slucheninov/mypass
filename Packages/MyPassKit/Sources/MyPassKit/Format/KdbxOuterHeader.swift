import Foundation

public enum KdbxCipher: Equatable {
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

public enum KdbxCompression: Equatable { case none, gzip }

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

/// Well-known KDF UUIDs stored in `kdfParameters["$UUID"]`.
enum KdbxKdfUUID {
    /// `KDF_AES_KDBX4` in KeePassXC's `src/format/KeePass2.cpp`
    /// (`7c02bb82-79a7-4ac0-927d-114a00648238`) — the UUID `AesKdf`'s
    /// default (KDBX4-native) constructor tags itself with.
    static let aesKdf = Data([0x7C, 0x02, 0xBB, 0x82, 0x79, 0xA7, 0x4A, 0xC0,
                              0x92, 0x7D, 0x11, 0x4A, 0x00, 0x64, 0x82, 0x38])
    /// `KDF_AES_KDBX3` in KeePassXC's `src/format/KeePass2.cpp`
    /// (`c9d9f39a-628a-4460-bf74-0d08c18a4fea`) — the legacy KDBX3-era
    /// AES-KDF UUID. Per `KeePass2::uuidToKdf()`, this constructs the exact
    /// same `AesKdf` class/algorithm as `aesKdf` above (just tagged
    /// differently, "for compatibility with other applications" per
    /// `AesKdf::writeParameters()`'s comment) — pykeepass's `create_database`
    /// (and many real-world KDBX4 files) use this UUID for AES-KDF, not the
    /// KDBX4-native one, so both must be treated identically on read.
    static let aesKdfLegacyKdbx3 = Data([0xC9, 0xD9, 0xF3, 0x9A, 0x62, 0x8A, 0x44, 0x60,
                                         0xBF, 0x74, 0x0D, 0x08, 0xC1, 0x8A, 0x4F, 0xEA])
    static let argon2d = Data([0xEF, 0x63, 0x6D, 0xDF, 0x8C, 0x29, 0x44, 0x4B,
                               0x91, 0xF7, 0xA9, 0xA4, 0x03, 0xE3, 0x0A, 0x0C])
    static let argon2id = Data([0x9E, 0x29, 0x8B, 0x19, 0x56, 0xDB, 0x47, 0x73,
                                0xB2, 0x3D, 0xFC, 0x3E, 0xC6, 0xF0, 0xA1, 0xE6])
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

    /// - Parameters:
    ///   - offset: Position (in/out) of the first outer-header TLV field. Advanced past
    ///     the EndOfHeader field on success.
    ///   - rawHeaderStart: Position in `data` where the raw header capture used for
    ///     `rawHeaderBytes` should begin. Pass the index where Signature+Version parsing
    ///     began (i.e. the very start of the file buffer) so `rawHeaderBytes` spans
    ///     Signature(8) + Version(4) + OuterHeaderFields through EndOfHeader inclusive,
    ///     as required for KDBX4 HeaderSHA256/HeaderHMAC-SHA256 verification (Task 7).
    ///     Defaults to `offset` (i.e. no signature/version prefix) when not provided.
    static func parse(from data: Data, startingAt offset: inout Data.Index, rawHeaderStart: Data.Index? = nil) throws -> KdbxOuterHeader {
        let headerStart = rawHeaderStart ?? offset
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
                    let missingFieldID: UInt8
                    if cipher == nil {
                        missingFieldID = KdbxHeaderFieldID.cipherID
                    } else if masterSeed == nil {
                        missingFieldID = KdbxHeaderFieldID.masterSeed
                    } else if encryptionIV == nil {
                        missingFieldID = KdbxHeaderFieldID.encryptionIV
                    } else {
                        missingFieldID = KdbxHeaderFieldID.kdfParameters
                    }
                    throw KdbxHeaderError.missingRequiredField(missingFieldID)
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

extension KdbxOuterHeader {
    /// Serializes this header back to the outer-header TLV byte stream
    /// (field ID (1 byte) + Int32 little-endian length + value, repeated),
    /// terminated by the EndOfHeader field. Does NOT include the
    /// Signature/Version prefix (Task 4's `KdbxSignature`) — callers that
    /// need `HeaderSHA256`/`HeaderHMAC-SHA256` over the full byte range must
    /// prepend that separately.
    func serialize() -> Data {
        var out = Data()

        func appendField(id: UInt8, value: Data) {
            out.append(id)
            out.append(contentsOf: withUnsafeBytes(of: Int32(value.count).littleEndian) { Data($0) })
            out.append(value)
        }

        let cipherUUID = (cipher == .aes256) ? KdbxCipher.aes256UUID : KdbxCipher.chaCha20UUID
        appendField(id: KdbxHeaderFieldID.cipherID, value: cipherUUID)

        let compressionFlag: Int32 = (compression == .gzip) ? 1 : 0
        appendField(id: KdbxHeaderFieldID.compressionFlags, value: withUnsafeBytes(of: compressionFlag.littleEndian) { Data($0) })

        appendField(id: KdbxHeaderFieldID.masterSeed, value: masterSeed)
        appendField(id: KdbxHeaderFieldID.encryptionIV, value: encryptionIV)
        appendField(id: KdbxHeaderFieldID.kdfParameters, value: kdfParameters.encode())

        if let publicCustomData {
            appendField(id: KdbxHeaderFieldID.publicCustomData, value: publicCustomData.encode())
        }

        appendField(id: KdbxHeaderFieldID.endOfHeader, value: Data([0x0D, 0x0A, 0x0D, 0x0A]))
        return out
    }
}
