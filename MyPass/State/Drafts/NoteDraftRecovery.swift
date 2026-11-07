import Foundation

/// Decides whether a stored draft is worth offering back to the user.
enum NoteDraftRecovery {
    /// Newest version whose text differs from what is saved in the vault and which was written
    /// after the entry's last modification. A draft at or before `entryLastModified` predates
    /// a real save (or a sync from another device) and would silently resurrect stale text.
    /// `versions` is newest first, as returned by `NoteDraftStore.versions`.
    static func pendingDraft(versions: [NoteDraftVersion],
                             savedNotes: String,
                             entryLastModified: Date) -> NoteDraftVersion? {
        versions.first { $0.notes != savedNotes && $0.savedAt > entryLastModified }
    }

    static func version(id: UUID, in versions: [NoteDraftVersion]) -> NoteDraftVersion? {
        versions.first { $0.id == id }
    }

    /// A draft whose entry is not in the open database: the note was never saved (crash, lock
    /// or Cancel before the first Save).
    struct Orphan: Equatable {
        let entryID: UUID
        let draft: NoteDraftVersion
    }

    /// Newest draft among entries absent from the database. The draft file does not record
    /// the entry type, so a notes editor may be offered a login-note draft and vice versa;
    /// any orphan is acceptable (restoring only fills the notes text).
    static func newestOrphan(candidates: [(entryID: UUID, versions: [NoteDraftVersion])],
                             databaseEntryIDs: Set<UUID>) -> Orphan? {
        var best: Orphan?
        for candidate in candidates where !databaseEntryIDs.contains(candidate.entryID) {
            guard let draft = candidate.versions.max(by: { $0.savedAt < $1.savedAt }) else { continue }
            if best == nil || draft.savedAt > best!.draft.savedAt {
                best = Orphan(entryID: candidate.entryID, draft: draft)
            }
        }
        return best
    }
}
