import Foundation

/// Field IDs for the KDBX4 inner header TLV stream. Format is identical to
/// the outer header (1-byte ID, 4-byte Int32LE length, N bytes of data), but
/// this stream lives inside the already-decrypted and decompressed HMAC
/// block payload, immediately preceding the XML document.
private enum InnerHeaderFieldID {
    static let end: UInt8 = 0
    static let innerRandomStreamID: UInt8 = 1
    static let innerRandomStreamKey: UInt8 = 2
    static let binary: UInt8 = 3
}

/// A single embedded binary attachment stored in the inner header. KDBX4
/// supports zero or more of these; they are referenced by index from the
/// XML payload (Task 13/14).
struct KdbxInnerBinary: Equatable {
    var isProtected: Bool
    var content: Data
}

enum KdbxInnerHeaderError: Error, Equatable {
    case truncated
    case missingRequiredField
    case unknownStreamID(UInt32)
}

/// Parses and serializes the KDBX4 inner header: the TLV block that sits at
/// the start of the decrypted-and-decompressed payload (after the outer
/// cipher from Tasks 9/10 and gzip decompression from Task 16), immediately
/// before the XML document. It carries the parameters (`InnerRandomStreamID`,
/// `InnerRandomStreamKey`) that `InnerRandomStreamCipher` (Task 11) needs to
/// de-obfuscate protected string values inside that XML, plus any embedded
/// binary attachments.
struct KdbxInnerHeader: Equatable {
    var innerRandomStreamID: InnerRandomStreamID
    var innerRandomStreamKey: Data
    var binaries: [KdbxInnerBinary]

    /// Parses the inner header TLV fields starting at `offset` within
    /// `data`. On success, `offset` is advanced past the terminating `End`
    /// field, pointing exactly at the first byte of the XML payload — this
    /// is how Task 15's facade knows where to hand off to the XML decoder.
    static func parse(from data: Data, startingAt offset: inout Data.Index) throws -> KdbxInnerHeader {
        var streamID: InnerRandomStreamID?
        var streamKey: Data?
        var binaries: [KdbxInnerBinary] = []

        while true {
            guard data.distance(from: offset, to: data.endIndex) >= 5 else {
                throw KdbxInnerHeaderError.truncated
            }
            let id = data[offset]
            offset = data.index(after: offset)
            let lenData = data[offset..<data.index(offset, offsetBy: 4)]
            let length = Int(lenData.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }.littleEndian)
            offset = data.index(offset, offsetBy: 4)
            guard length >= 0, data.distance(from: offset, to: data.endIndex) >= length else {
                throw KdbxInnerHeaderError.truncated
            }
            let fieldData = Data(data[offset..<data.index(offset, offsetBy: length)])
            offset = data.index(offset, offsetBy: length)

            switch id {
            case InnerHeaderFieldID.end:
                guard let streamID, let streamKey else {
                    throw KdbxInnerHeaderError.missingRequiredField
                }
                return KdbxInnerHeader(innerRandomStreamID: streamID, innerRandomStreamKey: streamKey, binaries: binaries)
            case InnerHeaderFieldID.innerRandomStreamID:
                guard fieldData.count == 4 else { throw KdbxInnerHeaderError.truncated }
                let raw = fieldData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
                guard let parsed = InnerRandomStreamID(rawValue: raw) else {
                    throw KdbxInnerHeaderError.unknownStreamID(raw)
                }
                streamID = parsed
            case InnerHeaderFieldID.innerRandomStreamKey:
                streamKey = fieldData
            case InnerHeaderFieldID.binary:
                guard let flags = fieldData.first else { throw KdbxInnerHeaderError.truncated }
                let isProtected = (flags & 0x01) != 0
                binaries.append(KdbxInnerBinary(isProtected: isProtected, content: Data(fieldData.dropFirst())))
            default:
                // Unknown field: format requires readers to tolerate and
                // skip fields they don't recognize, per outer-header
                // precedent (Task 4).
                break
            }
        }
    }

    /// Serializes back to the exact inner-header TLV byte layout that
    /// `parse` consumes: `InnerRandomStreamID`, `InnerRandomStreamKey`, each
    /// `Binary` (in order), then the terminating `End` field.
    func serialize() -> Data {
        var out = Data()
        func appendField(id: UInt8, value: Data) {
            out.append(id)
            out.append(contentsOf: withUnsafeBytes(of: Int32(value.count).littleEndian) { Data($0) })
            out.append(value)
        }
        appendField(id: InnerHeaderFieldID.innerRandomStreamID,
                    value: withUnsafeBytes(of: innerRandomStreamID.rawValue.littleEndian) { Data($0) })
        appendField(id: InnerHeaderFieldID.innerRandomStreamKey, value: innerRandomStreamKey)
        for binary in binaries {
            var value = Data([binary.isProtected ? 0x01 : 0x00])
            value.append(binary.content)
            appendField(id: InnerHeaderFieldID.binary, value: value)
        }
        appendField(id: InnerHeaderFieldID.end, value: Data())
        return out
    }
}
