import Foundation

/// Tracks which single entry currently has its notes revealed. Only one entry can be
/// revealed at a time, so switching entries (or locking) naturally re-hides everything.
struct NotesRevealState: Equatable {
    private(set) var revealedEntryID: UUID?

    mutating func reveal(entryID: UUID) {
        revealedEntryID = entryID
    }

    mutating func hide() {
        revealedEntryID = nil
    }

    func isRevealed(entryID: UUID) -> Bool {
        revealedEntryID == entryID
    }
}

enum NotesProtection {
    /// Purpose: protection against accidental reveal and screen sharing, not against a
    /// determined local attacker. Empty (or whitespace-only) notes have nothing to hide,
    /// so they are never blurred.
    static func isBlurred(notes: String, state: NotesRevealState, entryID: UUID) -> Bool {
        guard !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return !state.isRevealed(entryID: entryID)
    }
}
