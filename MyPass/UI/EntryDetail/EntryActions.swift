import AppKit
import Foundation
import MyPassKit

/// Vault-mutating and clipboard actions shared by the ⋮ menu and the visible action row.
///
/// The detail views still carry their own private `copy` / move / restore helpers; this
/// enum deliberately duplicates their behaviour rather than refactoring them in the same
/// change, so the new row can reuse one implementation while the old call sites stay
/// untouched until they are retired.
enum EntryActions {
    static func toggleFavorite(entryID: UUID, in vaultSession: VaultSession) {
        vaultSession.mutate { database in
            guard let location = GroupTreeOperations.entryLocation(entryID: entryID, in: database.rootGroup) else { return }
            var updated = location.group.entries[location.index]
            updated.isFavorite.toggle()
            updated.lastModificationTime = Date()
            EntryPersistence.replaceEntry(updated, in: database.rootGroup)
        }
    }

    static func move(entryID: UUID, toGroup groupID: UUID, in vaultSession: VaultSession) {
        vaultSession.mutate { database in
            GroupTreeOperations.moveEntry(withID: entryID, to: groupID, in: database.rootGroup)
        }
    }

    static func moveToRecycleBin(entryID: UUID, in vaultSession: VaultSession) {
        vaultSession.mutate { database in
            GroupTreeOperations.softDeleteEntry(
                withID: entryID,
                in: database.rootGroup,
                deletedObjects: &database.deletedObjects,
                recycleBinGroupUUID: &database.recycleBinGroupUUID
            )
        }
    }

    /// The entry's original source group isn't tracked once soft-deleted, so root is the
    /// safe, predictable restore destination (same as the inline Restore button).
    static func restore(entryID: UUID, in vaultSession: VaultSession) {
        vaultSession.mutate { database in
            GroupTreeOperations.restoreEntry(withID: entryID, to: database.rootGroup.uuid, in: database.rootGroup)
        }
    }

    static func deletePermanently(entryID: UUID, in vaultSession: VaultSession) {
        vaultSession.mutate { database in
            GroupTreeOperations.permanentlyDeleteEntry(withID: entryID, in: database.rootGroup, deletedObjects: &database.deletedObjects)
        }
    }

    /// Same sequence as the detail views' private `copy`: put the value on the general
    /// pasteboard, schedule the auto-clear with the user's interval (the clear only fires
    /// if the pasteboard still holds this value), and record the access on the entry.
    static func copy(_ value: String, entryID: UUID, in vaultSession: VaultSession) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        ClipboardAutoClear.schedule(
            value: value,
            after: ClipboardClearInterval.seconds(),
            pasteboard: NSPasteboardClearing(),
            clock: RealAutoLockClock()
        )
        vaultSession.touchAccess(entryID: entryID)
    }

    static func openWebsite(_ urlString: String) {
        let normalized = urlString.contains("://") ? urlString : "https://\(urlString)"
        guard let url = URL(string: normalized) else { return }
        NSWorkspace.shared.open(url)
    }
}
