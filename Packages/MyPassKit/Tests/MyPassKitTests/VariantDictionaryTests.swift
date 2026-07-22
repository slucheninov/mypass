import XCTest
@testable import MyPassKit

final class VariantDictionaryTests: XCTestCase {
    func testEncodeDecodeRoundTrip() throws {
        var dict = VariantDictionary()
        dict.items["$UUID"] = .byteArray(Data([0x9e, 0x29, 0x8b, 0x19, 0x56, 0xdb, 0x47, 0x73,
                                                0xb2, 0x3d, 0xfc, 0x3e, 0xc6, 0xf0, 0xa1, 0xe6]))
        dict.items["M"] = .uint64(65536)
        dict.items["I"] = .uint64(3)
        dict.items["P"] = .uint32(4)
        dict.items["V"] = .uint32(0x13)
        dict.items["S"] = .byteArray(Data(repeating: 0x02, count: 16))

        let encoded = dict.encode()
        let decoded = try VariantDictionary.decode(encoded)

        XCTAssertEqual(decoded, dict)
    }

    func testDecodeTruncatedDataThrows() {
        XCTAssertThrowsError(try VariantDictionary.decode(Data([0x00, 0x01]))) { error in
            guard case VariantDictionaryError.truncated = error else {
                return XCTFail("expected .truncated, got \(error)")
            }
        }
    }

    func testEncodeDecodeEmptyDictionary() throws {
        let dict = VariantDictionary()
        let encoded = dict.encode()
        let decoded = try VariantDictionary.decode(encoded)
        XCTAssertEqual(decoded, dict)
    }

    func testAllValueTypesRoundTrip() throws {
        var dict = VariantDictionary()
        dict.items["u32"] = .uint32(0xDEADBEEF)
        dict.items["u64"] = .uint64(0xDEADBEEFCAFEBABE)
        dict.items["b"] = .bool(true)
        dict.items["i32"] = .int32(-12345)
        dict.items["i64"] = .int64(-9_000_000_000)
        dict.items["s"] = .string("hello world")
        dict.items["ba"] = .byteArray(Data([0x01, 0x02, 0x03]))

        let encoded = dict.encode()
        let decoded = try VariantDictionary.decode(encoded)
        XCTAssertEqual(decoded, dict)
    }

    func testDecodeUnknownTypeThrows() {
        // version 0x0100 LE, then a single entry with an unknown type byte 0xFF,
        // name length 0, value length 0
        var data = Data([0x00, 0x01])
        data.append(0xFF)
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // name length = 0
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // value length = 0
        XCTAssertThrowsError(try VariantDictionary.decode(data)) { error in
            guard case VariantDictionaryError.unknownType(0xFF) = error else {
                return XCTFail("expected .unknownType(0xFF), got \(error)")
            }
        }
    }

    func testDecodeInvalidVersionThrows() {
        // version 0x0200 LE is not the expected 0x01xx major version
        let data = Data([0x00, 0x02, 0x00])
        XCTAssertThrowsError(try VariantDictionary.decode(data)) { error in
            guard case VariantDictionaryError.invalidVersion(0x0200) = error else {
                return XCTFail("expected .invalidVersion(0x0200), got \(error)")
            }
        }
    }
}
