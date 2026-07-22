import Foundation

/// A node in the database's group tree. This is a reference type (`class`) rather
/// than a `struct` because the tree is mutable and navigated in both directions by
/// the UI (children via `subgroups`/`entries`, parent via identity lookup) — a value
/// type would force awkward copy-on-write semantics for what is conceptually a
/// single shared tree. Equality is by value (uuid/name/iconID/entries/subgroups),
/// not by reference identity, so tests and later merge logic can compare snapshots.
public final class KdbxGroup: Equatable, Identifiable {
    public var uuid: UUID
    public var name: String
    public var iconID: Int
    public var creationTime: Date
    public var lastModificationTime: Date
    public var locationChanged: Date
    public var entries: [KdbxEntry]
    public var subgroups: [KdbxGroup]

    public init(
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

    public static func == (lhs: KdbxGroup, rhs: KdbxGroup) -> Bool {
        lhs.uuid == rhs.uuid &&
        lhs.name == rhs.name &&
        lhs.iconID == rhs.iconID &&
        lhs.creationTime == rhs.creationTime &&
        lhs.lastModificationTime == rhs.lastModificationTime &&
        lhs.locationChanged == rhs.locationChanged &&
        lhs.entries == rhs.entries &&
        lhs.subgroups == rhs.subgroups
    }

    public var id: UUID { uuid }
}
