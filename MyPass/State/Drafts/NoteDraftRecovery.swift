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
}
