import MyPassKit

extension KdbxGroup {
    /// Recursively builds a fully independent copy of this group and every
    /// subgroup beneath it — new `KdbxGroup` class instances at every level,
    /// not just a shallow reference copy. Needed before handing a `KdbxDatabase`
    /// snapshot to a background queue: `KdbxGroup` is a reference type, so a
    /// plain struct-level copy of `KdbxDatabase` still shares the same live
    /// group tree that the main thread keeps mutating via `VaultSession.mutate`.
    func deepCopy() -> KdbxGroup {
        KdbxGroup(
            uuid: uuid,
            name: name,
            iconID: iconID,
            creationTime: creationTime,
            lastModificationTime: lastModificationTime,
            locationChanged: locationChanged,
            entries: entries,
            subgroups: subgroups.map { $0.deepCopy() }
        )
    }
}
