import XCTest
@testable import MyPassKit

final class KdbxXmlCoderAttachmentTests: XCTestCase {
    private let t = Date(timeIntervalSince1970: 1_700_000_000)

    private func entry(_ attachments: [KdbxAttachment], history: [KdbxEntry] = []) -> KdbxEntry {
        KdbxEntry(uuid: UUID(), iconID: 0,
                  fields: [KdbxField(key: "Title", value: "T", isProtected: false)],
                  attachments: attachments, creationTime: t, lastModificationTime: t,
                  lastAccessTime: t, locationChanged: t, history: history)
    }

    private func payload(_ entries: [KdbxEntry]) -> KdbxXmlPayload {
        let root = KdbxGroup(uuid: UUID(), name: "Root", iconID: 0, creationTime: t,
                             lastModificationTime: t, locationChanged: t,
                             entries: entries, subgroups: [])
        return KdbxXmlPayload(rootGroup: root, deletedObjects: [])
    }

    private func att(_ name: String, _ bytes: [UInt8], protected: Bool = true) -> KdbxAttachment {
        KdbxAttachment(name: name, data: Data(bytes), isProtected: protected)
    }

    private let identity: (Data) -> Data = { $0 }

    private func nodes(_ xml: Data, _ xpath: String) throws -> [XMLNode] {
        try XMLDocument(data: xml).nodes(forXPath: xpath)
    }

    func testEncodeEmitsBinaryReferencesForEntryAndHistory() throws {
        let a = att("a.txt", [1, 2, 3])
        let old = att("a.txt", [1, 2, 3])
        let p = payload([entry([a], history: [entry([old])])])
        let pool = KdbxAttachmentPool(collecting: p.rootGroup)
        let xml = KdbxXmlCoder.encode(p, pool: pool, obfuscate: identity)
        XCTAssertEqual(try nodes(xml, "//Root/Group/Entry/Binary/Key").first?.stringValue, "a.txt")
        XCTAssertEqual(try nodes(xml, "//Root/Group/Entry/Binary/Value/@Ref").first?.stringValue, "0")
        XCTAssertEqual(try nodes(xml, "//History/Entry/Binary/Value/@Ref").first?.stringValue, "0")
    }

    func testEncodeWithoutAttachmentsEmitsNoBinaryElements() throws {
        let p = payload([entry([], history: [entry([])])])
        let withPool = KdbxXmlCoder.encode(p, pool: KdbxAttachmentPool(collecting: p.rootGroup), obfuscate: identity)
        let legacy = KdbxXmlCoder.encode(p, obfuscate: identity)
        XCTAssertEqual(withPool, legacy)
        XCTAssertTrue(try nodes(legacy, "//Binary").isEmpty)
    }

    func testEncodeEmitsBinaryAfterStringsAndBeforeHistory() throws {
        let p = payload([entry([att("a", [1])], history: [entry([])])])
        let xml = KdbxXmlCoder.encode(p, pool: KdbxAttachmentPool(collecting: p.rootGroup), obfuscate: identity)
        let names = try nodes(xml, "//Root/Group/Entry/*").compactMap(\.name)
        let binary = try XCTUnwrap(names.firstIndex(of: "Binary"))
        XCTAssertGreaterThan(binary, try XCTUnwrap(names.lastIndex(of: "String")))
        XCTAssertLessThan(binary, try XCTUnwrap(names.firstIndex(of: "History")))
    }

    private func xmlWithBinaries(_ refs: [(String, String)], history: Bool = false) throws -> Data {
        let base = payload([entry([])])
        var xml = String(decoding: KdbxXmlCoder.encode(base, obfuscate: identity), as: UTF8.self)
        let binaries = refs.map { "<Binary><Key>\($0.0)</Key><Value Ref=\"\($0.1)\"/></Binary>" }.joined()
        let injected = history ? "<History><Entry>" + injectedEntry(binaries) + "</Entry></History>" : binaries
        let range = try XCTUnwrap(xml.range(of: "</Entry>"))
        xml.replaceSubrange(range, with: injected + "</Entry>")
        return Data(xml.utf8)
    }

    private func injectedEntry(_ binaries: String) -> String {
        let id = UUID()
        let b64 = withUnsafeBytes(of: id.uuid) { Data($0).base64EncodedString() }
        let time = "<Times><CreationTime>AAAAAAAAAAA=</CreationTime><LastModificationTime>AAAAAAAAAAA=</LastModificationTime><LastAccessTime>AAAAAAAAAAA=</LastAccessTime><LocationChanged>AAAAAAAAAAA=</LocationChanged></Times>"
        return "<UUID>\(b64)</UUID><IconID>0</IconID>\(time)\(binaries)"
    }

    func testDecodeResolvesRefsAndKeepsProtectedFlagFromInnerBinary() throws {
        let xml = try xmlWithBinaries([("p.bin", "1"), ("q.bin", "0")])
        let bins = [KdbxInnerBinary(isProtected: false, content: Data([7])),
                    KdbxInnerBinary(isProtected: true, content: Data([8, 9]))]
        let decoded = try KdbxXmlCoder.decode(xml, binaries: bins, deobfuscate: identity)
        XCTAssertEqual(decoded.rootGroup.entries[0].attachments, [
            KdbxAttachment(name: "p.bin", data: Data([8, 9]), isProtected: true),
            KdbxAttachment(name: "q.bin", data: Data([7]), isProtected: false)
        ])
    }

    func testDecodeResolvesHistoryRefsAgainstSamePool() throws {
        let xml = try xmlWithBinaries([("h.bin", "0")], history: true)
        let bins = [KdbxInnerBinary(isProtected: true, content: Data([5]))]
        let decoded = try KdbxXmlCoder.decode(xml, binaries: bins, deobfuscate: identity)
        XCTAssertEqual(decoded.rootGroup.entries[0].history[0].attachments,
                       [KdbxAttachment(name: "h.bin", data: Data([5]), isProtected: true)])
    }

    func testDecodeSkipsDanglingAndNonNumericRefsWithoutThrowing() throws {
        let xml = try xmlWithBinaries([("gone", "7"), ("bad", "x"), ("neg", "-1"), ("ok", "0")])
        let bins = [KdbxInnerBinary(isProtected: true, content: Data([1]))]
        let decoded = try KdbxXmlCoder.decode(xml, binaries: bins, deobfuscate: identity)
        XCTAssertEqual(decoded.rootGroup.entries[0].fields.first?.value, "T")
        XCTAssertEqual(decoded.rootGroup.entries[0].attachments.map(\.name), ["ok"])
        let none = try KdbxXmlCoder.decode(try xmlWithBinaries([("gone", "7"), ("bad", "x")]),
                                           binaries: bins, deobfuscate: identity)
        XCTAssertEqual(none.rootGroup.entries[0].attachments, [])
    }

    func testDuplicateNamesWithinOneEntryAreBothPreserved() throws {
        let p = payload([entry([att("dup.txt", [1]), att("dup.txt", [2])])])
        let pool = KdbxAttachmentPool(collecting: p.rootGroup)
        let xml = KdbxXmlCoder.encode(p, pool: pool, obfuscate: identity)
        let decoded = try KdbxXmlCoder.decode(xml, binaries: pool.binaries, deobfuscate: identity)
        XCTAssertEqual(decoded.rootGroup.entries[0].attachments.map(\.data), [Data([1]), Data([2])])
    }

    func testAttachmentNameWithXmlSpecialCharsAndUnicodeRoundTrips() throws {
        let names = ["a&b <1>.txt", "отчёт.pdf"]
        let p = payload([entry(names.enumerated().map { att($1, [UInt8($0)]) })])
        let pool = KdbxAttachmentPool(collecting: p.rootGroup)
        let xml = KdbxXmlCoder.encode(p, pool: pool, obfuscate: identity)
        let decoded = try KdbxXmlCoder.decode(xml, binaries: pool.binaries, deobfuscate: identity)
        XCTAssertEqual(decoded.rootGroup.entries[0].attachments.map(\.name), names)
    }

    func testEncodeDecodeRoundTripWithPool() throws {
        let shared = att("s.bin", [4, 4], protected: false)
        let p = payload([
            entry([att("a", [1]), shared], history: [entry([att("a", [1])])]),
            entry([att("b", [2]), shared])
        ])
        let pool = KdbxAttachmentPool(collecting: p.rootGroup)
        let xml = KdbxXmlCoder.encode(p, pool: pool, obfuscate: identity)
        let decoded = try KdbxXmlCoder.decode(xml, binaries: pool.binaries, deobfuscate: identity)
        XCTAssertEqual(decoded, p)
    }
}
