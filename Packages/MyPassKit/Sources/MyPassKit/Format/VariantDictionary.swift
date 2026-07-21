import Foundation

enum VariantValue: Equatable {
    case uint32(UInt32), uint64(UInt64), bool(Bool), int32(Int32), int64(Int64)
    case string(String), byteArray(Data)

    fileprivate var typeByte: UInt8 {
        switch self {
        case .uint32: return 0x04
        case .uint64: return 0x05
        case .bool: return 0x08
        case .int32: return 0x0C
        case .int64: return 0x0D
        case .string: return 0x18
        case .byteArray: return 0x42
        }
    }

    fileprivate var payload: Data {
        switch self {
        case .uint32(let v): return withUnsafeBytes(of: v.littleEndian) { Data($0) }
        case .uint64(let v): return withUnsafeBytes(of: v.littleEndian) { Data($0) }
        case .bool(let v): return Data([v ? 1 : 0])
        case .int32(let v): return withUnsafeBytes(of: v.littleEndian) { Data($0) }
        case .int64(let v): return withUnsafeBytes(of: v.littleEndian) { Data($0) }
        case .string(let v): return Data(v.utf8)
        case .byteArray(let v): return v
        }
    }
}

enum VariantDictionaryError: Error, Equatable {
    case truncated
    case unknownType(UInt8)
    case invalidVersion(UInt16)
}

struct VariantDictionary: Equatable {
    var items: [String: VariantValue]

    init(items: [String: VariantValue] = [:]) {
        self.items = items
    }

    static func decode(_ data: Data) throws -> VariantDictionary {
        var offset = data.startIndex

        func readBytes(_ count: Int) throws -> Data {
            guard count >= 0, data.distance(from: offset, to: data.endIndex) >= count else {
                throw VariantDictionaryError.truncated
            }
            let end = data.index(offset, offsetBy: count)
            let slice = Data(data[offset..<end])
            offset = end
            return slice
        }
        func readUInt16() throws -> UInt16 {
            let bytes = try readBytes(2)
            return bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian
        }
        func readInt32() throws -> Int32 {
            let bytes = try readBytes(4)
            return bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }.littleEndian
        }

        let version = try readUInt16()
        guard version & 0xFF00 == 0x0100 else {
            throw VariantDictionaryError.invalidVersion(version)
        }

        var items: [String: VariantValue] = [:]
        while true {
            let typeByte = try readBytes(1)[0]
            if typeByte == 0x00 { break }

            let nameLength = Int(try readInt32())
            let nameData = try readBytes(nameLength)
            guard let name = String(data: nameData, encoding: .utf8) else {
                throw VariantDictionaryError.truncated
            }
            let valueLength = Int(try readInt32())
            let valueData = try readBytes(valueLength)

            let value: VariantValue
            switch typeByte {
            case 0x04:
                guard valueData.count == 4 else { throw VariantDictionaryError.truncated }
                value = .uint32(valueData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
            case 0x05:
                guard valueData.count == 8 else { throw VariantDictionaryError.truncated }
                value = .uint64(valueData.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian)
            case 0x08:
                guard valueData.count == 1 else { throw VariantDictionaryError.truncated }
                value = .bool(valueData.first == 1)
            case 0x0C:
                guard valueData.count == 4 else { throw VariantDictionaryError.truncated }
                value = .int32(valueData.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }.littleEndian)
            case 0x0D:
                guard valueData.count == 8 else { throw VariantDictionaryError.truncated }
                value = .int64(valueData.withUnsafeBytes { $0.loadUnaligned(as: Int64.self) }.littleEndian)
            case 0x18:
                guard let s = String(data: valueData, encoding: .utf8) else {
                    throw VariantDictionaryError.truncated
                }
                value = .string(s)
            case 0x42:
                value = .byteArray(valueData)
            default:
                throw VariantDictionaryError.unknownType(typeByte)
            }
            items[name] = value
        }
        return VariantDictionary(items: items)
    }

    func encode() -> Data {
        var out = Data()
        out.append(contentsOf: withUnsafeBytes(of: UInt16(0x0100).littleEndian) { Data($0) })
        for (name, value) in items {
            out.append(value.typeByte)
            let nameData = Data(name.utf8)
            out.append(contentsOf: withUnsafeBytes(of: Int32(nameData.count).littleEndian) { Data($0) })
            out.append(nameData)
            let payload = value.payload
            out.append(contentsOf: withUnsafeBytes(of: Int32(payload.count).littleEndian) { Data($0) })
            out.append(payload)
        }
        out.append(0x00)
        return out
    }
}
