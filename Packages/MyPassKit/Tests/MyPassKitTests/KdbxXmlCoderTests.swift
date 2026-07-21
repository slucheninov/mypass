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
}
