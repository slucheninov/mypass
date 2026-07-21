import Foundation

/// The decoded (or to-be-encoded) contents of the KDBX4 XML payload: the group
/// tree rooted at `rootGroup`, plus the flat list of tombstones for objects
/// deleted since the last sync.
struct KdbxXmlPayload: Equatable {
    var rootGroup: KdbxGroup
    var deletedObjects: [KdbxDeletedObject]
}

enum KdbxXmlCoderError: Error, Equatable {
    case malformedXml
    case missingRequiredElement(String)
}

/// Encodes/decodes the KDBX4 XML tree (`KeePassFile/Root/Group/Entry/String/...`).
///
/// This layer is deliberately crypto-agnostic: it does not know about the inner
/// random stream cipher. Callers supply `obfuscate`/`deobfuscate` closures which
/// are applied, in document order, to exactly the protected field values (this
/// is where `InnerRandomStreamCipher.nextBytes(_:)` from Task 11 plugs in, one
/// call per protected `<Value>` element, in the order those elements appear).
///
/// KDBX4 XML conventions (verified against KeePassXC's `KdbxXmlWriter.cpp`,
/// `writeUuid`/`writeDateTime`):
/// - UUIDs are base64 of the raw 16 bytes (NOT a hyphenated hex string).
/// - Dates (`Times/*`) are base64 of a little-endian `Int64` counting seconds
///   since `0001-01-01 00:00:00 UTC` (NOT an ISO8601 string — that's the KDBX3
///   convention). The epoch offset from Unix time is 62_135_596_800 seconds.
enum KdbxXmlCoder {
    private static let kdbxEpochOffsetFromUnix: Int64 = 62_135_596_800

    static func encode(_ payload: KdbxXmlPayload, obfuscate: (Data) -> Data) -> Data {
        let keePassFile = XMLElement(name: "KeePassFile")
        keePassFile.addChild(XMLElement(name: "Meta"))

        let rootElement = XMLElement(name: "Root")
        rootElement.addChild(groupElement(payload.rootGroup, obfuscate: obfuscate))

        let deletedObjectsElement = XMLElement(name: "DeletedObjects")
        for deleted in payload.deletedObjects {
            let el = XMLElement(name: "DeletedObject")
            el.addChild(textElement("UUID", base64(fromUuid: deleted.uuid)))
            el.addChild(textElement("DeletionTime", base64(fromDate: deleted.deletionTime)))
            deletedObjectsElement.addChild(el)
        }
        rootElement.addChild(deletedObjectsElement)
        keePassFile.addChild(rootElement)

        let document = XMLDocument(rootElement: keePassFile)
        document.version = "1.0"
        document.characterEncoding = "UTF-8"
        return document.xmlData
    }

    static func decode(_ xml: Data, deobfuscate: (Data) -> Data) throws -> KdbxXmlPayload {
        let document: XMLDocument
        do {
            // Hardened against XXE: this XML comes from decrypting a KDBX4 file,
            // which may be corrupted, tampered with, or maliciously crafted (e.g.
            // shared/synced from an untrusted source). `.nodeLoadExternalEntitiesNever`
            // disables resolution of ALL external entities/DTDs — including
            // non-network (local file) ones — regardless of what the file's own
            // <!DOCTYPE>/<!ENTITY> declarations request, preventing arbitrary local
            // file read, SSRF-style requests, and entity-expansion ("billion laughs") DoS.
            document = try XMLDocument(data: xml, options: [.nodeLoadExternalEntitiesNever])
        } catch {
            throw KdbxXmlCoderError.malformedXml
        }

        guard let keePassFile = document.rootElement() else {
            throw KdbxXmlCoderError.missingRequiredElement("KeePassFile")
        }
        guard let rootElement = keePassFile.elements(forName: "Root").first else {
            throw KdbxXmlCoderError.missingRequiredElement("Root")
        }
        guard let groupElement = rootElement.elements(forName: "Group").first else {
            throw KdbxXmlCoderError.missingRequiredElement("Group")
        }
        let rootGroup = try parseGroup(groupElement, deobfuscate: deobfuscate)

        var deletedObjects: [KdbxDeletedObject] = []
        if let deletedObjectsElement = rootElement.elements(forName: "DeletedObjects").first {
            for el in deletedObjectsElement.elements(forName: "DeletedObject") {
                guard let uuidString = el.elements(forName: "UUID").first?.stringValue,
                      let uuid = uuid(fromBase64: uuidString),
                      let dateString = el.elements(forName: "DeletionTime").first?.stringValue,
                      let date = date(fromBase64: dateString) else {
                    throw KdbxXmlCoderError.malformedXml
                }
                deletedObjects.append(KdbxDeletedObject(uuid: uuid, deletionTime: date))
            }
        }
        return KdbxXmlPayload(rootGroup: rootGroup, deletedObjects: deletedObjects)
    }

    // MARK: - Group / Entry / String

    private static func groupElement(_ group: KdbxGroup, obfuscate: (Data) -> Data) -> XMLElement {
        let el = XMLElement(name: "Group")
        el.addChild(textElement("UUID", base64(fromUuid: group.uuid)))
        el.addChild(textElement("Name", group.name))
        el.addChild(textElement("IconID", String(group.iconID)))
        el.addChild(timesElement(
            creationTime: group.creationTime,
            lastModificationTime: group.lastModificationTime,
            lastAccessTime: nil,
            locationChanged: group.locationChanged
        ))
        for entry in group.entries {
            el.addChild(entryElement(entry, obfuscate: obfuscate))
        }
        for subgroup in group.subgroups {
            el.addChild(groupElement(subgroup, obfuscate: obfuscate))
        }
        return el
    }

    private static func entryElement(_ entry: KdbxEntry, obfuscate: (Data) -> Data) -> XMLElement {
        let el = XMLElement(name: "Entry")
        el.addChild(textElement("UUID", base64(fromUuid: entry.uuid)))
        el.addChild(textElement("IconID", String(entry.iconID)))
        el.addChild(timesElement(
            creationTime: entry.creationTime,
            lastModificationTime: entry.lastModificationTime,
            lastAccessTime: entry.lastAccessTime,
            locationChanged: entry.locationChanged
        ))
        for field in entry.fields {
            el.addChild(stringFieldElement(field, obfuscate: obfuscate))
        }
        if !entry.history.isEmpty {
            let historyElement = XMLElement(name: "History")
            for historicalEntry in entry.history {
                historyElement.addChild(entryElement(historicalEntry, obfuscate: obfuscate))
            }
            el.addChild(historyElement)
        }
        return el
    }

    private static func stringFieldElement(_ field: KdbxField, obfuscate: (Data) -> Data) -> XMLElement {
        let el = XMLElement(name: "String")
        el.addChild(textElement("Key", field.key))
        let valueElement: XMLElement
        if field.isProtected {
            let obfuscated = obfuscate(Data(field.value.utf8))
            valueElement = textElement("Value", obfuscated.base64EncodedString())
            // Safe force-cast: `XMLNode.attribute(withName:stringValue:)` is a plain
            // string-based factory (declared `+ (id)` non-nullable in Foundation's
            // NSXMLNode.h, with no parsing/validation that could fail for arbitrary
            // strings), so it always returns an `XMLNode` here. This is also on the
            // encode path over our own trusted in-memory model, not attacker-controlled
            // parsed XML, so there is no realistic failure mode to guard against.
            let attribute = XMLNode.attribute(withName: "Protected", stringValue: "True") as! XMLNode
            valueElement.addAttribute(attribute)
        } else {
            valueElement = textElement("Value", field.value)
        }
        el.addChild(valueElement)
        return el
    }

    private static func timesElement(
        creationTime: Date,
        lastModificationTime: Date,
        lastAccessTime: Date?,
        locationChanged: Date
    ) -> XMLElement {
        let el = XMLElement(name: "Times")
        el.addChild(textElement("CreationTime", base64(fromDate: creationTime)))
        el.addChild(textElement("LastModificationTime", base64(fromDate: lastModificationTime)))
        if let lastAccessTime {
            el.addChild(textElement("LastAccessTime", base64(fromDate: lastAccessTime)))
        }
        el.addChild(textElement("LocationChanged", base64(fromDate: locationChanged)))
        return el
    }

    // MARK: - Parsing

    private static func parseGroup(_ element: XMLElement, deobfuscate: (Data) -> Data) throws -> KdbxGroup {
        guard let uuidString = element.elements(forName: "UUID").first?.stringValue,
              let uuid = uuid(fromBase64: uuidString) else {
            throw KdbxXmlCoderError.malformedXml
        }
        let name = element.elements(forName: "Name").first?.stringValue ?? ""
        let iconID = Int(element.elements(forName: "IconID").first?.stringValue ?? "0") ?? 0

        let times = element.elements(forName: "Times").first
        let creationTime = try date(fromTimes: times, elementName: "CreationTime")
        let lastModificationTime = try date(fromTimes: times, elementName: "LastModificationTime")
        let locationChanged = try date(fromTimes: times, elementName: "LocationChanged")

        var entries: [KdbxEntry] = []
        for entryEl in element.elements(forName: "Entry") {
            entries.append(try parseEntry(entryEl, deobfuscate: deobfuscate))
        }
        var subgroups: [KdbxGroup] = []
        for groupEl in element.elements(forName: "Group") {
            subgroups.append(try parseGroup(groupEl, deobfuscate: deobfuscate))
        }
        return KdbxGroup(
            uuid: uuid, name: name, iconID: iconID,
            creationTime: creationTime, lastModificationTime: lastModificationTime,
            locationChanged: locationChanged, entries: entries, subgroups: subgroups
        )
    }

    private static func parseEntry(_ element: XMLElement, deobfuscate: (Data) -> Data) throws -> KdbxEntry {
        guard let uuidString = element.elements(forName: "UUID").first?.stringValue,
              let uuid = uuid(fromBase64: uuidString) else {
            throw KdbxXmlCoderError.malformedXml
        }
        let iconID = Int(element.elements(forName: "IconID").first?.stringValue ?? "0") ?? 0

        let times = element.elements(forName: "Times").first
        let creationTime = try date(fromTimes: times, elementName: "CreationTime")
        let lastModificationTime = try date(fromTimes: times, elementName: "LastModificationTime")
        let lastAccessTime = try date(fromTimes: times, elementName: "LastAccessTime")
        let locationChanged = try date(fromTimes: times, elementName: "LocationChanged")

        var fields: [KdbxField] = []
        for stringEl in element.elements(forName: "String") {
            guard let key = stringEl.elements(forName: "Key").first?.stringValue,
                  let valueEl = stringEl.elements(forName: "Value").first else {
                throw KdbxXmlCoderError.malformedXml
            }
            let isProtected = (valueEl.attribute(forName: "Protected")?.stringValue == "True")
            let rawValue = valueEl.stringValue ?? ""
            let value: String
            if isProtected {
                guard let obfuscatedData = Data(base64Encoded: rawValue) else {
                    throw KdbxXmlCoderError.malformedXml
                }
                guard let decodedValue = String(data: deobfuscate(obfuscatedData), encoding: .utf8) else {
                    throw KdbxXmlCoderError.malformedXml
                }
                value = decodedValue
            } else {
                value = rawValue
            }
            fields.append(KdbxField(key: key, value: value, isProtected: isProtected))
        }

        var history: [KdbxEntry] = []
        if let historyElement = element.elements(forName: "History").first {
            for historicalEl in historyElement.elements(forName: "Entry") {
                history.append(try parseEntry(historicalEl, deobfuscate: deobfuscate))
            }
        }

        return KdbxEntry(
            uuid: uuid, iconID: iconID, fields: fields,
            creationTime: creationTime, lastModificationTime: lastModificationTime,
            lastAccessTime: lastAccessTime, locationChanged: locationChanged, history: history
        )
    }

    private static func date(fromTimes times: XMLElement?, elementName: String) throws -> Date {
        guard let base64String = times?.elements(forName: elementName).first?.stringValue,
              let parsed = date(fromBase64: base64String) else {
            throw KdbxXmlCoderError.missingRequiredElement("Times/\(elementName)")
        }
        return parsed
    }

    // MARK: - Primitive encoding helpers

    private static func textElement(_ name: String, _ text: String) -> XMLElement {
        XMLElement(name: name, stringValue: text)
    }

    private static func base64(fromUuid uuid: UUID) -> String {
        withUnsafeBytes(of: uuid.uuid) { Data($0) }.base64EncodedString()
    }

    private static func uuid(fromBase64 base64String: String) -> UUID? {
        guard let data = Data(base64Encoded: base64String), data.count == 16 else { return nil }
        let bytes = [UInt8](data)
        let raw: uuid_t = (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: raw)
    }

    /// KDBX4 dates: base64 of a little-endian Int64 count of seconds since
    /// 0001-01-01 00:00:00 UTC (not ISO8601 — that's the KDBX3 convention).
    // Note: unlike `date(fromBase64:)`, this path's input is an internal `Date`
    // value (not attacker/file-controlled file bytes), and `Date`'s representable
    // range is nowhere near Int64's overflow boundary once combined with
    // `kdbxEpochOffsetFromUnix`, so plain arithmetic is left as-is here.
    private static func base64(fromDate date: Date) -> String {
        let secondsSinceUnixEpoch = Int64(date.timeIntervalSince1970.rounded())
        let secondsSinceKdbxEpoch = secondsSinceUnixEpoch + kdbxEpochOffsetFromUnix
        var littleEndianValue = secondsSinceKdbxEpoch.littleEndian
        let data = withUnsafeBytes(of: &littleEndianValue) { Data($0) }
        return data.base64EncodedString()
    }

    private static func date(fromBase64 base64String: String) -> Date? {
        guard let data = Data(base64Encoded: base64String), data.count == 8 else { return nil }
        var storage: Int64 = 0
        withUnsafeMutableBytes(of: &storage) { destination in
            data.withUnsafeBytes { source in
                destination.copyBytes(from: source)
            }
        }
        let secondsSinceKdbxEpoch = Int64(littleEndian: storage)
        // `secondsSinceKdbxEpoch` is read verbatim from file bytes, so it may be
        // any Int64 value (including near Int64.min/Int64.max) in a corrupted or
        // maliciously crafted database. Plain `-` traps on overflow, which would
        // crash the app (a DoS on open); use checked subtraction and fail
        // gracefully instead.
        let (secondsSinceUnixEpoch, overflowed) = secondsSinceKdbxEpoch.subtractingReportingOverflow(kdbxEpochOffsetFromUnix)
        guard !overflowed else { return nil }
        return Date(timeIntervalSince1970: Double(secondsSinceUnixEpoch))
    }
}
