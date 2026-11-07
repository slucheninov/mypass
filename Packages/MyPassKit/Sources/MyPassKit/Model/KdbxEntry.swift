import Foundation

/// A single named field on an entry (e.g. "Title", "Password", or a custom field).
/// `isProtected` marks fields that must be memory-protected / encrypted in the XML
/// inner stream (per the KDBX4 format) — the model just carries the flag; the XML
/// layer (Task 14) is responsible for acting on it.
public struct KdbxField: Equatable {
    public var key: String
    public var value: String
    public var isProtected: Bool

    public init(key: String, value: String, isProtected: Bool) {
        self.key = key
        self.value = value
        self.isProtected = isProtected
    }
}

/// One KDBX `<StringArray>` element — a repeated-value field. MyPass currently
/// only reads/writes this shape for the `KP2A_URL` additional-URLs convention
/// (see `KdbxEntry+Convenience.urls` in the app target); unrecognized StringArray
/// keys round-trip opaquely through this same storage.
public struct KdbxStringArray: Equatable {
    public var key: String
    public var values: [String]

    public init(key: String, values: [String]) {
        self.key = key
        self.values = values
    }
}

/// A file attached to an entry (KDBX `<Binary>` entry element plus its inner-header
/// binary). The bytes are embedded per entry rather than held in a database-level
/// pool so that history snapshots and `MergeEngine` copy attachment data together
/// with the entry value; the coder rebuilds (and deduplicates) the shared pool at
/// save time.
public struct KdbxAttachment: Equatable {
    public var name: String
    public var data: Data
    /// Whether the inner-header binary carries the KDBX "memory protected" flag.
    /// Defaults to `true` for new attachments (the conservative choice); flags read
    /// from an existing vault are preserved verbatim by the coder.
    public var isProtected: Bool

    public init(name: String, data: Data, isProtected: Bool = true) {
        self.name = name
        self.data = data
        self.isProtected = isProtected
    }
}

/// A password entry: title/login/password/URL/notes/TOTP/custom fields are all
/// represented uniformly as `KdbxField`s (matching the KDBX4 XML model), plus
/// entry-level metadata and a `history` of past versions of itself.
///
/// By convention (and per the design spec's history semantics), entries stored
/// inside `history` are themselves snapshots with an empty `history` — history
/// does not nest.
public struct KdbxEntry: Equatable, Identifiable {
    public var uuid: UUID
    public var iconID: Int
    public var fields: [KdbxField]
    public var stringArrays: [KdbxStringArray]
    public var attachments: [KdbxAttachment]
    public var creationTime: Date
    public var lastModificationTime: Date
    public var lastAccessTime: Date
    public var locationChanged: Date
    public var history: [KdbxEntry]

    public init(
        uuid: UUID,
        iconID: Int,
        fields: [KdbxField],
        stringArrays: [KdbxStringArray] = [],
        attachments: [KdbxAttachment] = [],
        creationTime: Date,
        lastModificationTime: Date,
        lastAccessTime: Date,
        locationChanged: Date,
        history: [KdbxEntry]
    ) {
        self.uuid = uuid
        self.iconID = iconID
        self.fields = fields
        self.stringArrays = stringArrays
        self.attachments = attachments
        self.creationTime = creationTime
        self.lastModificationTime = lastModificationTime
        self.lastAccessTime = lastAccessTime
        self.locationChanged = locationChanged
        self.history = history
    }

    public var id: UUID { uuid }
}
