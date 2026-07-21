import Foundation

/// A single named field on an entry (e.g. "Title", "Password", or a custom field).
/// `isProtected` marks fields that must be memory-protected / encrypted in the XML
/// inner stream (per the KDBX4 format) — the model just carries the flag; the XML
/// layer (Task 14) is responsible for acting on it.
struct KdbxField: Equatable {
    var key: String
    var value: String
    var isProtected: Bool

    init(key: String, value: String, isProtected: Bool) {
        self.key = key
        self.value = value
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
struct KdbxEntry: Equatable {
    var uuid: UUID
    var iconID: Int
    var fields: [KdbxField]
    var creationTime: Date
    var lastModificationTime: Date
    var lastAccessTime: Date
    var locationChanged: Date
    var history: [KdbxEntry]

    init(
        uuid: UUID,
        iconID: Int,
        fields: [KdbxField],
        creationTime: Date,
        lastModificationTime: Date,
        lastAccessTime: Date,
        locationChanged: Date,
        history: [KdbxEntry]
    ) {
        self.uuid = uuid
        self.iconID = iconID
        self.fields = fields
        self.creationTime = creationTime
        self.lastModificationTime = lastModificationTime
        self.lastAccessTime = lastAccessTime
        self.locationChanged = locationChanged
        self.history = history
    }
}
