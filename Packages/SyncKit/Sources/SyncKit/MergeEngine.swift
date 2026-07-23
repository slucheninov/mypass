import Foundation
import MyPassKit

public enum MergeEngine {
    /// Merges two divergent copies of the same logical database, `local` and
    /// `remote`, using KeePassXC-style per-object merge semantics keyed by
    /// UUID. Pure function: no I/O, does not mutate its arguments.
    public static func merge(local: KdbxDatabase, remote: KdbxDatabase) -> KdbxDatabase {
        let localEntries = collectEntries(in: local.rootGroup)
        let remoteEntries = collectEntries(in: remote.rootGroup)
        let localGroups = collectGroups(in: local.rootGroup)
        let remoteGroups = collectGroups(in: remote.rootGroup)

        let localEntryParents = collectEntryParents(in: local.rootGroup)
        let remoteEntryParents = collectEntryParents(in: remote.rootGroup)

        // Rule 7: union deletedObjects by uuid, keeping the later deletionTime.
        var deletedByUUID: [UUID: KdbxDeletedObject] = [:]
        for object in local.deletedObjects + remote.deletedObjects {
            if let existing = deletedByUUID[object.uuid] {
                deletedByUUID[object.uuid] = existing.deletionTime >= object.deletionTime ? existing : object
            } else {
                deletedByUUID[object.uuid] = object
            }
        }

        // Rule 5: resurrect uuids whose surviving edit is newer than their
        // recorded deletion.
        var resurrectedUUIDs: Set<UUID> = []
        for (uuid, deletion) in deletedByUUID {
            let survivingModification = localEntries[uuid]?.lastModificationTime
                ?? remoteEntries[uuid]?.lastModificationTime
                ?? localGroups[uuid]?.lastModificationTime
                ?? remoteGroups[uuid]?.lastModificationTime
            if let survivingModification, survivingModification > deletion.deletionTime {
                resurrectedUUIDs.insert(uuid)
            }
        }
        for uuid in resurrectedUUIDs {
            deletedByUUID.removeValue(forKey: uuid)
        }

        let mergedDeletedObjects = Array(deletedByUUID.values)
        let deletedUUIDsAfterResurrection = Set(deletedByUUID.keys)

        let mergedRoot: KdbxGroup
        if local.rootGroup.uuid == remote.rootGroup.uuid {
            mergedRoot = mergeGroup(
                uuid: local.rootGroup.uuid,
                localGroup: local.rootGroup,
                remoteGroup: remote.rootGroup,
                localEntries: localEntries,
                remoteEntries: remoteEntries,
                localGroups: localGroups,
                remoteGroups: remoteGroups,
                localEntryParents: localEntryParents,
                remoteEntryParents: remoteEntryParents,
                deletedUUIDs: deletedUUIDsAfterResurrection
            )
        } else {
            mergedRoot = local.rootGroup
        }

        // Rule 8: recycleBinGroupUUID
        let mergedRecycleBinGroupUUID = local.recycleBinGroupUUID ?? remote.recycleBinGroupUUID

        return KdbxDatabase(
            rootGroup: mergedRoot,
            deletedObjects: mergedDeletedObjects,
            recycleBinGroupUUID: mergedRecycleBinGroupUUID
        )
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

    private static func collectEntryParents(in group: KdbxGroup) -> [UUID: UUID] {
        var result: [UUID: UUID] = [:]
        for entry in group.entries {
            result[entry.uuid] = group.uuid
        }
        for subgroup in group.subgroups {
            for (entryUUID, parentUUID) in collectEntryParents(in: subgroup) {
                result[entryUUID] = parentUUID
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
                return l
            }
        }
    }

    private static func appendToHistoryIfNeeded(winner: KdbxEntry, loser: KdbxEntry) -> KdbxEntry {
        var result = winner
        var loserForHistory = loser
        loserForHistory.history = []
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

    // MARK: - Parent disambiguation for moves (rule 6)

    private static func winningParentUUID(
        for entryUUID: UUID,
        localParentUUID: UUID?,
        remoteParentUUID: UUID?,
        localEntries: [UUID: KdbxEntry],
        remoteEntries: [UUID: KdbxEntry]
    ) -> UUID? {
        switch (localParentUUID, remoteParentUUID) {
        case (nil, nil):
            return nil
        case (let l?, nil):
            return l
        case (nil, let r?):
            return r
        case (let l?, let r?) where l == r:
            return l
        case (let l?, let r?):
            let localLocationChanged = localEntries[entryUUID]?.locationChanged ?? .distantPast
            let remoteLocationChanged = remoteEntries[entryUUID]?.locationChanged ?? .distantPast
            return localLocationChanged >= remoteLocationChanged ? l : r
        }
    }

    // MARK: - Group merge (rules 3, 4, 5, 6, 9)

    private static func mergeGroup(
        uuid: UUID,
        localGroup: KdbxGroup?,
        remoteGroup: KdbxGroup?,
        localEntries: [UUID: KdbxEntry],
        remoteEntries: [UUID: KdbxEntry],
        localGroups: [UUID: KdbxGroup],
        remoteGroups: [UUID: KdbxGroup],
        localEntryParents: [UUID: UUID],
        remoteEntryParents: [UUID: UUID],
        deletedUUIDs: Set<UUID>
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

        let localChildEntryUUIDs = Set(localGroup?.entries.map(\.uuid) ?? [])
        let remoteChildEntryUUIDs = Set(remoteGroup?.entries.map(\.uuid) ?? [])
        let candidateEntryUUIDs = localChildEntryUUIDs.union(remoteChildEntryUUIDs)
            .subtracting(deletedUUIDs)

        let mergedEntries: [KdbxEntry] = candidateEntryUUIDs.compactMap { entryUUID -> KdbxEntry? in
            let winningParent = winningParentUUID(
                for: entryUUID,
                localParentUUID: localEntryParents[entryUUID],
                remoteParentUUID: remoteEntryParents[entryUUID],
                localEntries: localEntries,
                remoteEntries: remoteEntries
            )
            guard winningParent == uuid else { return nil }
            return mergeEntry(local: localEntries[entryUUID], remote: remoteEntries[entryUUID])
        }.sorted { $0.uuid.uuidString < $1.uuid.uuidString }

        let localChildGroupUUIDs = Set(localGroup?.subgroups.map(\.uuid) ?? [])
        let remoteChildGroupUUIDs = Set(remoteGroup?.subgroups.map(\.uuid) ?? [])
        let candidateGroupUUIDs = localChildGroupUUIDs.union(remoteChildGroupUUIDs)
            .subtracting(deletedUUIDs)

        let mergedSubgroups: [KdbxGroup] = candidateGroupUUIDs.compactMap { groupUUID -> KdbxGroup? in
            mergeGroup(
                uuid: groupUUID,
                localGroup: localGroups[groupUUID],
                remoteGroup: remoteGroups[groupUUID],
                localEntries: localEntries,
                remoteEntries: remoteEntries,
                localGroups: localGroups,
                remoteGroups: remoteGroups,
                localEntryParents: localEntryParents,
                remoteEntryParents: remoteEntryParents,
                deletedUUIDs: deletedUUIDs
            )
        }.sorted { $0.uuid.uuidString < $1.uuid.uuidString }

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
