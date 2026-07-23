import Foundation
import MyPassKit

public enum MergeEngine {
    /// Merges two divergent copies of the same logical database, `local` and
    /// `remote`, using KeePassXC-style per-object merge semantics keyed by
    /// UUID. Pure function: no I/O, does not mutate its arguments.
    ///
    /// This task implements rules 1-4 and 9 (additions, edits, group metadata
    /// vs. child merge independence, tree reconstruction). Rules 5-8
    /// (deletions, moves, deletedObjects union, recycle bin) are implemented
    /// in Task 5, which extends this same function.
    public static func merge(local: KdbxDatabase, remote: KdbxDatabase) -> KdbxDatabase {
        let localEntries = collectEntries(in: local.rootGroup)
        let remoteEntries = collectEntries(in: remote.rootGroup)
        let localGroups = collectGroups(in: local.rootGroup)
        let remoteGroups = collectGroups(in: remote.rootGroup)

        let mergedRoot: KdbxGroup
        if local.rootGroup.uuid == remote.rootGroup.uuid {
            mergedRoot = mergeGroup(
                uuid: local.rootGroup.uuid,
                localGroup: local.rootGroup,
                remoteGroup: remote.rootGroup,
                localEntries: localEntries,
                remoteEntries: remoteEntries,
                localGroups: localGroups,
                remoteGroups: remoteGroups
            )
        } else {
            // Known limitation: mismatched root UUIDs are not a supported
            // scenario (both databases are expected to share one synthetic
            // root UUID created once at first sync). Fall back to local's
            // root unchanged rather than attempting a cross-root merge.
            mergedRoot = local.rootGroup
        }

        // Rule 9 (naive placeholder, refined by Task 5): union deletedObjects
        // with no dedup.
        let mergedDeletedObjects = local.deletedObjects + remote.deletedObjects

        // Rule 8 (naive placeholder — this exact formula happens to already
        // match the final rule 8 logic Task 5 documents, since there is only
        // ever one recycle bin in practice; Task 5 does not need to change
        // this line): prefer local's recycleBinGroupUUID if present, else
        // remote's. `recycleBinGroupUUID` already exists as a public stored
        // property on `KdbxDatabase` (see `Packages/MyPassKit/Sources/MyPassKit/KdbxDatabase.swift`)
        // — this task only wires MergeEngine to read/pass it through.
        let mergedRecycleBinGroupUUID = local.recycleBinGroupUUID ?? remote.recycleBinGroupUUID

        return KdbxDatabase(rootGroup: mergedRoot, deletedObjects: mergedDeletedObjects, recycleBinGroupUUID: mergedRecycleBinGroupUUID)
    }

    // MARK: - Collection helpers

    private static func collectEntries(in group: KdbxGroup) -> [UUID: KdbxEntry] {
        var result: [UUID: KdbxEntry] = [:]
        for entry in group.entries {
            result[entry.uuid] = entry
        }
        for subgroup in group.subgroups {
            for (uuid, entry) in collectEntries(in: subgroup) {
                result[uuid] = entry
            }
        }
        return result
    }

    private static func collectGroups(in group: KdbxGroup) -> [UUID: KdbxGroup] {
        var result: [UUID: KdbxGroup] = [group.uuid: group]
        for subgroup in group.subgroups {
            for (uuid, g) in collectGroups(in: subgroup) {
                result[uuid] = g
            }
        }
        return result
    }

    // MARK: - Entry merge (rule 2)

    private static func mergeEntry(local: KdbxEntry?, remote: KdbxEntry?) -> KdbxEntry? {
        switch (local, remote) {
        case (nil, nil):
            return nil
        case (let l?, nil):
            return l
        case (nil, let r?):
            return r
        case (let l?, let r?):
            if l.lastModificationTime > r.lastModificationTime {
                return appendToHistoryIfNeeded(winner: l, loser: r)
            } else if r.lastModificationTime > l.lastModificationTime {
                return appendToHistoryIfNeeded(winner: r, loser: l)
            } else {
                // Equal timestamps: prefer local, no history append.
                return l
            }
        }
    }

    private static func appendToHistoryIfNeeded(winner: KdbxEntry, loser: KdbxEntry) -> KdbxEntry {
        var result = winner
        var loserForHistory = loser
        loserForHistory.history = [] // history entries themselves don't carry nested history
        let alreadyPresent = result.history.contains { historical in
            historical.uuid == loserForHistory.uuid &&
            historical.lastModificationTime == loserForHistory.lastModificationTime &&
            historical.fields == loserForHistory.fields
        }
        if !alreadyPresent {
            result.history.append(loserForHistory)
        }
        return result
    }

    // MARK: - Group merge (rules 3, 4, 9)

    private static func mergeGroup(
        uuid: UUID,
        localGroup: KdbxGroup?,
        remoteGroup: KdbxGroup?,
        localEntries: [UUID: KdbxEntry],
        remoteEntries: [UUID: KdbxEntry],
        localGroups: [UUID: KdbxGroup],
        remoteGroups: [UUID: KdbxGroup]
    ) -> KdbxGroup {
        let metadataSource: KdbxGroup
        switch (localGroup, remoteGroup) {
        case (let l?, let r?):
            metadataSource = l.lastModificationTime >= r.lastModificationTime ? l : r
        case (let l?, nil):
            metadataSource = l
        case (nil, let r?):
            metadataSource = r
        case (nil, nil):
            fatalError("mergeGroup called with no source for uuid \(uuid)")
        }

        // Child entry UUIDs present under this group on either side.
        let localChildEntryUUIDs = Set(localGroup?.entries.map(\.uuid) ?? [])
        let remoteChildEntryUUIDs = Set(remoteGroup?.entries.map(\.uuid) ?? [])
        let allChildEntryUUIDs = localChildEntryUUIDs.union(remoteChildEntryUUIDs)

        let mergedEntries: [KdbxEntry] = allChildEntryUUIDs.compactMap { entryUUID in
            mergeEntry(local: localEntries[entryUUID], remote: remoteEntries[entryUUID])
        }.sorted { $0.uuid.uuidString < $1.uuid.uuidString } // deterministic ordering for tests

        // Child subgroup UUIDs present under this group on either side.
        let localChildGroupUUIDs = Set(localGroup?.subgroups.map(\.uuid) ?? [])
        let remoteChildGroupUUIDs = Set(remoteGroup?.subgroups.map(\.uuid) ?? [])
        let allChildGroupUUIDs = localChildGroupUUIDs.union(remoteChildGroupUUIDs)

        let mergedSubgroups: [KdbxGroup] = allChildGroupUUIDs.map { groupUUID in
            mergeGroup(
                uuid: groupUUID,
                localGroup: localGroups[groupUUID],
                remoteGroup: remoteGroups[groupUUID],
                localEntries: localEntries,
                remoteEntries: remoteEntries,
                localGroups: localGroups,
                remoteGroups: remoteGroups
            )
        }.sorted { $0.uuid.uuidString < $1.uuid.uuidString } // deterministic ordering for tests

        return KdbxGroup(
            uuid: uuid,
            name: metadataSource.name,
            iconID: metadataSource.iconID,
            creationTime: metadataSource.creationTime,
            lastModificationTime: metadataSource.lastModificationTime,
            locationChanged: metadataSource.locationChanged,
            entries: mergedEntries,
            subgroups: mergedSubgroups
        )
    }
}
