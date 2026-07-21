import Foundation

/// A node in the database's group tree. This is a reference type (`class`) rather
/// than a `struct` because the tree is mutable and navigated in both directions by
/// the UI (children via `subgroups`/`entries`, parent via identity lookup) — a value
/// type would force awkward copy-on-write semantics for what is conceptually a
/// single shared tree. Equality is by value (uuid/name/iconID/entries/subgroups),
/// not by reference identity, so tests and later merge logic can compare snapshots.
final class KdbxGroup: Equatable {
    var uuid: UUID
    var name: String
    var iconID: Int
    var creationTime: Date
    var lastModificationTime: Date
    var locationChanged: Date
    var entries: [KdbxEntry]
    var subgroups: [KdbxGroup]

    init(
        uuid: UUID,
        name: String,
        iconID: Int,
        creationTime: Date,
        lastModificationTime: Date,
        locationChanged: Date,
        entries: [KdbxEntry],
        subgroups: [KdbxGroup]
    ) {
        self.uuid = uuid
        self.name = name
        self.iconID = iconID
        self.creationTime = creationTime
        self.lastModificationTime = lastModificationTime
        self.locationChanged = locationChanged
        self.entries = entries
        self.subgroups = subgroups
    }

    static func == (lhs: KdbxGroup, rhs: KdbxGroup) -> Bool {
        lhs.uuid == rhs.uuid &&
        lhs.name == rhs.name &&
        lhs.iconID == rhs.iconID &&
        lhs.creationTime == rhs.creationTime &&
        lhs.lastModificationTime == rhs.lastModificationTime &&
        lhs.locationChanged == rhs.locationChanged &&
        lhs.entries == rhs.entries &&
        lhs.subgroups == rhs.subgroups
    }
}
