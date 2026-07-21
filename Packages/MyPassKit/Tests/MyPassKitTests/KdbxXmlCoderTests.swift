import XCTest
@testable import MyPassKit

final class KdbxXmlCoderTests: XCTestCase {
    private func passthroughStream() -> (obfuscate: (Data) -> Data, deobfuscate: (Data) -> Data) {
        var encodeCounter: UInt8 = 0
        var decodeCounter: UInt8 = 0
        let obfuscate: (Data) -> Data = { data in
            Data(data.map { byte -> UInt8 in
                encodeCounter = encodeCounter &+ 1
                return byte ^ encodeCounter
            })
        }
        let deobfuscate: (Data) -> Data = { data in
            Data(data.map { byte -> UInt8 in
                decodeCounter = decodeCounter &+ 1
                return byte ^ decodeCounter
            })
        }
        return (obfuscate, deobfuscate)
    }

    func testEncodeDecodeRoundTripWithProtectedField() throws {
        let entry = KdbxEntry(
            uuid: UUID(),
            iconID: 0,
            fields: [
                KdbxField(key: "Title", value: "GitHub", isProtected: false),
                KdbxField(key: "Password", value: "s3cr3t", isProtected: true)
            ],
            creationTime: Date(timeIntervalSince1970: 1_700_000_000),
            lastModificationTime: Date(timeIntervalSince1970: 1_700_000_100),
            lastAccessTime: Date(timeIntervalSince1970: 1_700_000_100),
            locationChanged: Date(timeIntervalSince1970: 1_700_000_000),
            history: []
        )
        let root = KdbxGroup(
            uuid: UUID(), name: "Root", iconID: 0,
            creationTime: Date(timeIntervalSince1970: 1_700_000_000),
            lastModificationTime: Date(timeIntervalSince1970: 1_700_000_000),
            locationChanged: Date(timeIntervalSince1970: 1_700_000_000),
            entries: [entry], subgroups: []
        )
        let deleted = KdbxDeletedObject(uuid: UUID(), deletionTime: Date(timeIntervalSince1970: 1_700_000_050))
        let payload = KdbxXmlPayload(rootGroup: root, deletedObjects: [deleted])

        var keystreamCounter: UInt8 = 0
        func obfuscate(_ data: Data) -> Data {
            Data(data.map { byte -> UInt8 in
                keystreamCounter = keystreamCounter &+ 1
                return byte ^ keystreamCounter
            })
        }

        let xml = KdbxXmlCoder.encode(payload) { plaintext in obfuscate(plaintext) }

        keystreamCounter = 0
        let decoded = try KdbxXmlCoder.decode(xml) { ciphertext in obfuscate(ciphertext) }

        XCTAssertEqual(decoded.rootGroup.name, "Root")
        XCTAssertEqual(decoded.rootGroup.entries.count, 1)
        XCTAssertEqual(decoded.rootGroup.entries[0].fields.first(where: { $0.key == "Title" })?.value, "GitHub")
        XCTAssertEqual(decoded.rootGroup.entries[0].fields.first(where: { $0.key == "Password" })?.value, "s3cr3t")
        XCTAssertEqual(decoded.deletedObjects, payload.deletedObjects)
    }

    func testProtectedFieldValueIsMarkedProtectedInXmlAndNotPlaintext() throws {
        let entry = KdbxEntry(
            uuid: UUID(), iconID: 0,
            fields: [KdbxField(key: "Password", value: "s3cr3t", isProtected: true)],
            creationTime: Date(), lastModificationTime: Date(), lastAccessTime: Date(),
            locationChanged: Date(), history: []
        )
        let root = KdbxGroup(
            uuid: UUID(), name: "Root", iconID: 0,
            creationTime: Date(), lastModificationTime: Date(), locationChanged: Date(),
            entries: [entry], subgroups: []
        )
        let payload = KdbxXmlPayload(rootGroup: root, deletedObjects: [])
        let (obfuscate, _) = passthroughStream()

        let xml = KdbxXmlCoder.encode(payload, obfuscate: obfuscate)
        let xmlString = String(data: xml, encoding: .utf8)!

        XCTAssertTrue(xmlString.contains("Protected=\"True\""))
        XCTAssertFalse(xmlString.contains("s3cr3t"), "protected value must not appear as plaintext in the XML")
    }

    func testUuidIsEncodedAsBase64OfRawSixteenBytesNotHyphenatedString() throws {
        let uuid = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
        let entry = KdbxEntry(
            uuid: uuid, iconID: 0, fields: [],
            creationTime: Date(), lastModificationTime: Date(), lastAccessTime: Date(),
            locationChanged: Date(), history: []
        )
        let root = KdbxGroup(
            uuid: UUID(), name: "Root", iconID: 0,
            creationTime: Date(), lastModificationTime: Date(), locationChanged: Date(),
            entries: [entry], subgroups: []
        )
        let payload = KdbxXmlPayload(rootGroup: root, deletedObjects: [])
        let (obfuscate, _) = passthroughStream()

        let xml = KdbxXmlCoder.encode(payload, obfuscate: obfuscate)
        let xmlString = String(data: xml, encoding: .utf8)!

        let expectedBase64 = withUnsafeBytes(of: uuid.uuid) { Data($0) }.base64EncodedString()
        XCTAssertTrue(xmlString.contains(expectedBase64), "UUID must be base64 of raw 16 bytes per KDBX4 XML convention")
        XCTAssertFalse(xmlString.contains(uuid.uuidString), "UUID must not be encoded as a hyphenated hex string")
    }

    func testTimesAreEncodedAsBase64Int64SecondsSince0001NotISO8601() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let root = KdbxGroup(
            uuid: UUID(), name: "Root", iconID: 0,
            creationTime: date, lastModificationTime: date, locationChanged: date,
            entries: [], subgroups: []
        )
        let payload = KdbxXmlPayload(rootGroup: root, deletedObjects: [])
        let (obfuscate, _) = passthroughStream()

        let xml = KdbxXmlCoder.encode(payload, obfuscate: obfuscate)
        let xmlString = String(data: xml, encoding: .utf8)!

        let kdbxEpochOffset: Int64 = 62_135_596_800
        let secs = Int64(date.timeIntervalSince1970.rounded()) + kdbxEpochOffset
        var le = secs.littleEndian
        let expectedBase64 = withUnsafeBytes(of: &le) { Data($0) }.base64EncodedString()

        XCTAssertTrue(xmlString.contains(expectedBase64), "dates must be base64-encoded little-endian int64 seconds since 0001-01-01, per KDBX4 (not ISO8601)")
        // ISO8601 (KDBX3-style) would render as e.g. "2023-11-14T22:13:20Z" with
        // dashes and a trailing "Z" — assert none of that shape leaked into the XML.
        XCTAssertFalse(xmlString.contains("Z</"), "encoded XML should not contain ISO8601-style date strings")

        let (_, deobfuscate) = passthroughStream()
        let decoded = try KdbxXmlCoder.decode(xml, deobfuscate: deobfuscate)
        XCTAssertEqual(decoded.rootGroup.creationTime.timeIntervalSince1970.rounded(),
                       date.timeIntervalSince1970.rounded())
        XCTAssertEqual(decoded.rootGroup.lastModificationTime.timeIntervalSince1970.rounded(),
                       date.timeIntervalSince1970.rounded())
        XCTAssertEqual(decoded.rootGroup.locationChanged.timeIntervalSince1970.rounded(),
                       date.timeIntervalSince1970.rounded())
    }

    func testHistoryRoundTrips() throws {
        let oldEntry = KdbxEntry(
            uuid: UUID(), iconID: 0,
            fields: [KdbxField(key: "Title", value: "Old GitHub", isProtected: false)],
            creationTime: Date(timeIntervalSince1970: 1_600_000_000),
            lastModificationTime: Date(timeIntervalSince1970: 1_600_000_000),
            lastAccessTime: Date(timeIntervalSince1970: 1_600_000_000),
            locationChanged: Date(timeIntervalSince1970: 1_600_000_000),
            history: []
        )
        let currentEntry = KdbxEntry(
            uuid: UUID(), iconID: 0,
            fields: [KdbxField(key: "Title", value: "GitHub", isProtected: false)],
            creationTime: Date(timeIntervalSince1970: 1_700_000_000),
            lastModificationTime: Date(timeIntervalSince1970: 1_700_000_000),
            lastAccessTime: Date(timeIntervalSince1970: 1_700_000_000),
            locationChanged: Date(timeIntervalSince1970: 1_700_000_000),
            history: [oldEntry]
        )
        let root = KdbxGroup(
            uuid: UUID(), name: "Root", iconID: 0,
            creationTime: Date(), lastModificationTime: Date(), locationChanged: Date(),
            entries: [currentEntry], subgroups: []
        )
        let payload = KdbxXmlPayload(rootGroup: root, deletedObjects: [])
        let (obfuscate, deobfuscate) = passthroughStream()

        let xml = KdbxXmlCoder.encode(payload, obfuscate: obfuscate)
        let decoded = try KdbxXmlCoder.decode(xml, deobfuscate: deobfuscate)

        XCTAssertEqual(decoded.rootGroup.entries[0].history.count, 1)
        XCTAssertEqual(decoded.rootGroup.entries[0].history[0].fields.first?.value, "Old GitHub")
        XCTAssertTrue(decoded.rootGroup.entries[0].history[0].history.isEmpty)
    }

    func testNestedSubgroupsRoundTrip() throws {
        let leaf = KdbxGroup(
            uuid: UUID(), name: "Leaf", iconID: 1,
            creationTime: Date(), lastModificationTime: Date(), locationChanged: Date(),
            entries: [], subgroups: []
        )
        let root = KdbxGroup(
            uuid: UUID(), name: "Root", iconID: 0,
            creationTime: Date(), lastModificationTime: Date(), locationChanged: Date(),
            entries: [], subgroups: [leaf]
        )
        let payload = KdbxXmlPayload(rootGroup: root, deletedObjects: [])
        let (obfuscate, deobfuscate) = passthroughStream()

        let xml = KdbxXmlCoder.encode(payload, obfuscate: obfuscate)
        let decoded = try KdbxXmlCoder.decode(xml, deobfuscate: deobfuscate)

        XCTAssertEqual(decoded.rootGroup.subgroups.count, 1)
        XCTAssertEqual(decoded.rootGroup.subgroups[0].name, "Leaf")
        XCTAssertEqual(decoded.rootGroup.subgroups[0].iconID, 1)
    }

    func testDecodeMalformedXmlThrows() {
        let malformed = Data("not xml at all".utf8)
        XCTAssertThrowsError(try KdbxXmlCoder.decode(malformed) { $0 }) { error in
            XCTAssertEqual(error as? KdbxXmlCoderError, .malformedXml)
        }
    }

    func testDecodeMissingRootThrows() {
        let noRoot = Data("<KeePassFile><Meta/></KeePassFile>".utf8)
        XCTAssertThrowsError(try KdbxXmlCoder.decode(noRoot) { $0 }) { error in
            guard case .missingRequiredElement = error as? KdbxXmlCoderError else {
                return XCTFail("expected missingRequiredElement, got \(error)")
            }
        }
    }

    // MARK: - Security regressions

    /// A maliciously crafted KDBX4 XML payload declaring an external entity
    /// pointing at a local file. If `decode()` resolved external entities (XXE),
    /// the referenced file's contents would end up substituted into the parsed
    /// document's text content. This proves that does NOT happen: decode()
    /// either throws, or (if it tolerates the unknown elements/DTD) produces a
    /// result that provably does not contain the sentinel file's contents.
    func testDecodeDoesNotResolveExternalEntitiesXXE() throws {
        let sentinelFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("kdbx-xxe-sentinel-\(UUID().uuidString).txt")
        let sentinelContents = "XXE-SENTINEL-\(UUID().uuidString)"
        try sentinelContents.write(to: sentinelFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sentinelFile) }

        let maliciousXml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE KeePassFile [
          <!ENTITY xxe SYSTEM "file://\(sentinelFile.path)">
        ]>
        <KeePassFile>
          <Root>
            <Group>
              <UUID>&xxe;</UUID>
              <Name>&xxe;</Name>
            </Group>
          </Root>
        </KeePassFile>
        """
        let data = Data(maliciousXml.utf8)

        do {
            let decoded = try KdbxXmlCoder.decode(data) { $0 }
            // If decoding succeeded at all, the entity must NOT have been expanded
            // into the sentinel file's contents anywhere in the decoded payload.
            XCTAssertNotEqual(decoded.rootGroup.name, sentinelContents)
            XCTAssertFalse(decoded.rootGroup.name.contains(sentinelContents))
        } catch {
            // Throwing (e.g. malformedXml because the unresolved entity reference
            // makes the document invalid) is an acceptable, safe outcome too.
            XCTAssertTrue(error is KdbxXmlCoderError, "expected a typed KdbxXmlCoderError, got \(error)")
        }
    }

    /// A "billion laughs"-style payload: only internally-defined, recursively
    /// nested `<!ENTITY>` declarations, with NO external (SYSTEM/PUBLIC)
    /// reference at all. `.nodeLoadExternalEntitiesNever` (the mitigation for
    /// the XXE test above) only blocks resolution of EXTERNAL entities — it
    /// does nothing to stop this kind of internal entity expansion, which can
    /// blow up a tiny document into gigabytes of memory. Before the DOCTYPE
    /// rejection fix, this payload would parse and its innermost element's
    /// text content would fully expand to 2^9 = 512 repetitions of "lol" (small
    /// here only so the test itself stays fast and doesn't OOM the test
    /// runner — the exploit scales the same way to many more expansion levels).
    /// decode() must now throw `.disallowedDoctype` before any expansion happens.
    func testDecodeRejectsBillionLaughsStyleInternalEntityExpansion() {
        let lolEntities = (1...9).map { level -> String in
            if level == 1 {
                return "<!ENTITY lol1 \"lol\">"
            }
            let previous = "&lol\(level - 1);&lol\(level - 1);"
            return "<!ENTITY lol\(level) \"\(previous)\">"
        }.joined(separator: "\n  ")

        let billionLaughsXml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE KeePassFile [
          \(lolEntities)
        ]>
        <KeePassFile>
          <Root>
            <Group>
              <UUID>&lol9;</UUID>
              <Name>&lol9;</Name>
            </Group>
          </Root>
        </KeePassFile>
        """
        let data = Data(billionLaughsXml.utf8)

        XCTAssertThrowsError(try KdbxXmlCoder.decode(data) { $0 }) { error in
            XCTAssertEqual(error as? KdbxXmlCoderError, .disallowedDoctype,
                           "any <!DOCTYPE, including internal-entity-only ones with no external reference, must be rejected before parsing/expansion")
        }
    }

    /// A UTF-16-encoded payload containing a DOCTYPE (with a billion-laughs-style
    /// internal entity expansion) is a bypass of the `<!DOCTYPE` byte-scan: that
    /// scan looks for the contiguous UTF-8 byte sequence `<!DOCTYPE`, but in
    /// UTF-16 those same characters are interleaved with null bytes and never
    /// match. Before the UTF-8-validity check, this payload would sail past the
    /// scan and be handed straight to `XMLDocument`, which auto-detects the
    /// UTF-16 encoding (via the BOM) and would fully parse/expand it. decode()
    /// must now reject this outright as `.unsupportedEncoding`, before the
    /// DOCTYPE scan or any `XMLDocument` construction is even attempted.
    func testDecodeRejectsUtf16EncodedPayloadBypassingDoctypeScan() {
        let lolEntities = (1...9).map { level -> String in
            if level == 1 {
                return "<!ENTITY lol1 \"lol\">"
            }
            let previous = "&lol\(level - 1);&lol\(level - 1);"
            return "<!ENTITY lol\(level) \"\(previous)\">"
        }.joined(separator: "\n  ")

        let billionLaughsXml = """
        <?xml version="1.0" encoding="UTF-16"?>
        <!DOCTYPE KeePassFile [
          \(lolEntities)
        ]>
        <KeePassFile>
          <Root>
            <Group>
              <UUID>&lol9;</UUID>
              <Name>&lol9;</Name>
            </Group>
          </Root>
        </KeePassFile>
        """
        // Encode as UTF-16 (with BOM) so libxml2 would auto-detect this encoding
        // and the `<!DOCTYPE` bytes are interleaved with nulls, never matching
        // the UTF-8 byte-scan.
        guard let data = billionLaughsXml.data(using: .utf16) else {
            return XCTFail("failed to construct UTF-16 test payload")
        }
        // Sanity-check the exploit shape: the raw bytes must NOT contain the
        // contiguous UTF-8 "<!DOCTYPE" sequence (proving this would bypass the
        // byte-scan alone), yet must also not be valid UTF-8 (proving the new
        // check catches it).
        XCTAssertNil(data.range(of: Data("<!DOCTYPE".utf8)))
        XCTAssertNil(String(data: data, encoding: .utf8))

        XCTAssertThrowsError(try KdbxXmlCoder.decode(data) { $0 }) { error in
            XCTAssertEqual(error as? KdbxXmlCoderError, .unsupportedEncoding,
                           "non-UTF-8 payloads must be rejected before the DOCTYPE scan or XML parsing")
        }
    }

    /// `Times/*` values are base64 of an attacker/file-controlled little-endian
    /// Int64. A value near Int64.min, once combined with the KDBX epoch offset,
    /// would overflow plain `Int64` subtraction and trap (crash the process).
    /// decode() must instead throw a typed error.
    func testDecodeDateNearInt64MinThrowsInsteadOfCrashing() {
        var extreme = Int64.min.littleEndian
        let base64Extreme = withUnsafeBytes(of: &extreme) { Data($0) }.base64EncodedString()

        let uuid = UUID()
        let uuidBase64 = withUnsafeBytes(of: uuid.uuid) { Data($0) }.base64EncodedString()

        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <KeePassFile>
          <Root>
            <Group>
              <UUID>\(uuidBase64)</UUID>
              <Name>Root</Name>
              <Times>
                <CreationTime>\(base64Extreme)</CreationTime>
                <LastModificationTime>\(base64Extreme)</LastModificationTime>
                <LocationChanged>\(base64Extreme)</LocationChanged>
              </Times>
            </Group>
          </Root>
        </KeePassFile>
        """
        let data = Data(xml.utf8)

        XCTAssertThrowsError(try KdbxXmlCoder.decode(data) { $0 }) { error in
            guard case .missingRequiredElement = error as? KdbxXmlCoderError else {
                return XCTFail("expected missingRequiredElement (date overflow treated as unparsable), got \(error)")
            }
        }
    }
}
