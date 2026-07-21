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
    /// The XML payload contains a `<!DOCTYPE` declaration. KDBX4's real XML
    /// payload (as written by KeePassXC and other conformant implementations)
    /// never legitimately contains a DOCTYPE/DTD, so this is rejected outright
    /// rather than parsed. See `decode(_:deobfuscate:)` for why.
    case disallowedDoctype
    /// The raw payload is not valid, unambiguous UTF-8 (e.g. it is UTF-16/UTF-32
    /// encoded, or carries a BOM signalling such). The real KDBX4 file format
    /// mandates a UTF-8 XML payload; rejecting anything else closes an encoding
    /// bypass of the `<!DOCTYPE` byte-scan below. See `decode(_:deobfuscate:)`.
    case unsupportedEncoding
    /// The XML prolog declares a character `encoding="..."` other than UTF-8
    /// (e.g. `encoding="UTF-7"`). Even though the raw bytes were just confirmed
    /// to be valid UTF-8 with no NUL bytes, an explicit non-UTF-8 `encoding=`
    /// declaration is the ONLY lever by which libxml2 can subsequently
    /// reinterpret those same bytes under a different codec (UTF-7 has no
    /// BOM/byte-pattern signature, so it is only reachable this way). This is
    /// the root-cause fix: it closes the entire "declare a non-UTF-8 encoding
    /// name in the prolog" bypass class, not just UTF-7. See
    /// `decode(_:deobfuscate:)`.
    case disallowedEncodingDeclaration
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

    /// The literal ASCII byte sequence that opens an XML DOCTYPE declaration.
    /// Checked verbatim (case-sensitively) against the raw payload bytes before
    /// any parsing occurs — this is how DOCTYPE declarations are written in XML;
    /// there is no case-insensitive spelling to worry about.
    private static let doctypeMarker = Data("<!DOCTYPE".utf8)

    static func decode(_ xml: Data, deobfuscate: (Data) -> Data) throws -> KdbxXmlPayload {
        // `XMLDocument(data:options:)` auto-detects character encoding from a
        // BOM or the XML prolog's `encoding="..."` attribute, and can happily
        // parse UTF-16/UTF-32 input. The `<!DOCTYPE` byte-scan below only
        // matches a contiguous UTF-8/ASCII byte sequence — in a UTF-16-encoded
        // payload those same characters are interleaved with null bytes (e.g.
        // `3C 00 21 00 44 4F 43 ...`) and would silently slip past the scan,
        // letting a DOCTYPE-based entity-expansion (or XXE) payload reach
        // libxml2 undetected. The real KDBX4 file format mandates a UTF-8 XML
        // payload (this codec's own `encode()` always sets
        // `characterEncoding = "UTF-8"`, matching KeePassXC), so requiring the
        // raw bytes to be valid, unambiguous UTF-8 before doing anything else
        // enforces the actual format contract and closes this bypass class
        // generically (also naturally covers UTF-32 and any other alternate
        // encoding) rather than trying to enumerate every non-UTF-8 encoding
        // name or BOM signature individually.
        //
        // That `String(data:encoding:.utf8)` check alone is NOT sufficient,
        // though: a BOM-less UTF-16 (or UTF-32) encoding of pure ASCII-range
        // content is a byte stream where every individual byte — including the
        // `0x00` bytes interleaved between/around each ASCII character — is
        // independently a valid single-byte UTF-8 code point (0x00-0x7F all
        // are). So `String(data:encoding:.utf8)` on such bytes wrongly
        // succeeds, the `<!DOCTYPE` byte-scan below fails to match (the nulls
        // break up the contiguous ASCII pattern), and libxml2's own encoding
        // auto-detection (from byte patterns alone, no BOM required) still
        // parses it as UTF-16/UTF-32 and fully expands any internal DTD
        // entities — reproducing the exact billion-laughs DoS this whole
        // check exists to prevent. Reject any raw NUL byte outright, before
        // both the UTF-8 check and the DOCTYPE scan: the XML spec disallows a
        // literal NUL character in well-formed XML/UTF-8 text, so no real
        // KDBX4 payload (always written UTF-8 by conforming writers,
        // including this codec's own `encode()`) ever legitimately contains
        // one, whereas any BOM-less UTF-16/UTF-32 encoding of ASCII content is
        // saturated with NUL bytes (roughly half, or three-quarters for
        // UTF-32).
        guard !xml.contains(0) else {
            throw KdbxXmlCoderError.unsupportedEncoding
        }
        guard let xmlText = String(data: xml, encoding: .utf8) else {
            throw KdbxXmlCoderError.unsupportedEncoding
        }

        // Root-cause fix (round 6, hardened round 7): the raw bytes are now
        // confirmed to be valid UTF-8 with no NUL bytes. The ONLY remaining
        // way for libxml2 to subsequently interpret this same UTF-8 byte
        // stream under a *different* text encoding (e.g. UTF-7,
        // EBCDIC-via-declared-charset, etc.) is an explicit `encoding="..."`
        // attribute in the leading XML declaration naming that encoding:
        // unlike UTF-16/UTF-32, UTF-7 has no BOM or detectable byte-pattern
        // signature, so libxml2 only ever switches to it via this declared
        // name. `XMLDocument(data:options:)` receives nothing but these raw
        // bytes (no side-channel/external metadata), so closing this one
        // lever closes the entire encoding-declaration bypass class in one
        // place, rather than adding another per-encoding heuristic.
        //
        // A conforming XML declaration must be the very first thing in the
        // document (libxml2 only honors `<?xml ...?>` when it starts at byte
        // 0), so only documents that literally start with `<?xml` need any
        // scanning at all — anything else falls back to the default UTF-8
        // interpretation, which the checks above already confirmed the bytes
        // satisfy. Round 6 scanned only `xmlText.prefix(512)` on the theory
        // that no real prolog needs more than that — but XML permits
        // arbitrary whitespace between the `version=`, `encoding=`, and
        // `standalone=` pseudo-attributes, so an attacker can pad
        // `version="1.0"` with hundreds of spaces to push `encoding="UTF-7"`
        // past that fixed window while libxml2 (which sees the whole file,
        // not a truncated prefix) still honors it. The round 7 fix scans the
        // FULL `<?xml ...?>` declaration — from index 0 through the first
        // `?>` — with no character cap on the declaration itself. To keep
        // this from becoming an unbounded scan on a pathological input that
        // starts with `<?xml` but never closes the declaration, the search
        // for `?>` is bounded to the first 64KB of the document: a real
        // declaration, however absurdly padded, has no legitimate reason to
        // need anywhere near that much space, so failing to find `?>` within
        // 64KB is itself treated as malformed input.
        if xmlText.hasPrefix("<?xml") {
            let utf8View = xmlText.utf8
            let searchLimit = utf8View.index(
                utf8View.startIndex, offsetBy: 65_536, limitedBy: utf8View.endIndex
            ) ?? utf8View.endIndex
            let boundedSearchSpace = xmlText[xmlText.startIndex..<searchLimit]
            guard let closeRange = boundedSearchSpace.range(of: "?>") else {
                throw KdbxXmlCoderError.malformedXml
            }
            let declaration = String(xmlText[xmlText.startIndex..<closeRange.upperBound])
            if let encodingRegex = try? NSRegularExpression(
                pattern: "(?:^|\\s)encoding\\s*=\\s*[\"']([^\"']+)[\"']",
                options: [.caseInsensitive]
            ) {
                let nsDeclaration = declaration as NSString
                if let match = encodingRegex.firstMatch(
                    in: declaration,
                    options: [],
                    range: NSRange(location: 0, length: nsDeclaration.length)
                ), match.numberOfRanges > 1 {
                    let declaredEncoding = nsDeclaration.substring(with: match.range(at: 1))
                    let normalized = declaredEncoding.lowercased().replacingOccurrences(of: "-", with: "")
                    if normalized != "utf8" {
                        throw KdbxXmlCoderError.disallowedEncodingDeclaration
                    }
                }
            }
        }

        // Reject any DOCTYPE declaration outright, before handing the data to
        // the XML parser. This is a KDBX4 file that may be corrupted, tampered
        // with, or maliciously crafted (e.g. shared/synced from an untrusted
        // source), and a real KDBX4 XML payload (as written by KeePassXC and
        // other conformant implementations) never legitimately contains a
        // DOCTYPE/DTD. `.nodeLoadExternalEntitiesNever` below prevents the
        // parser from *resolving* EXTERNAL (SYSTEM/PUBLIC) entities, but it does
        // NOT stop DTD-internal, recursively-nested `<!ENTITY>` definitions from
        // being expanded ("billion laughs" DoS) — that attack needs no external
        // reference at all. Refusing any DOCTYPE up front closes both the
        // internal-entity-expansion DoS and any residual external-entity path,
        // in one place, without depending on parser-specific option semantics.
        if xml.range(of: doctypeMarker) != nil {
            throw KdbxXmlCoderError.disallowedDoctype
        }

        let document: XMLDocument
        do {
            // Defense in depth against XXE (SYSTEM/PUBLIC external entities):
            // even though DOCTYPEs are already rejected above, keep this so a
            // parser-level bypass of the textual check above still can't reach
            // an external resource.
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
