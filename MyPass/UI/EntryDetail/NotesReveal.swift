import Combine
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
    /// Single definition of "has notes": whitespace-only notes count as empty everywhere
    /// (row visibility, blur, copy gating).
    static func hasContent(_ notes: String) -> Bool {
        !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Purpose: protection against accidental reveal and screen sharing, not against a
    /// determined local attacker. Empty (or whitespace-only) notes have nothing to hide,
    /// so they are never blurred.
    static func isBlurred(notes: String, state: NotesRevealState, entryID: UUID) -> Bool {
        guard hasContent(notes) else { return false }
        return !state.isRevealed(entryID: entryID)
    }
}

/// Re-hides revealed notes whenever the vault locks, independent of any window. A
/// ContentView `onChange` only runs while a window exists, so a lock with the main window
/// closed (app living in the menu bar) would otherwise leave the reveal in place for the
/// next unlock.
final class NotesAutoHide {
    private var cancellable: AnyCancellable?

    init<P: Publisher>(locked: P, navigationState: NavigationState) where P.Output == Bool, P.Failure == Never {
        cancellable = locked
            .removeDuplicates()
            .sink { [weak navigationState] isLocked in
                if isLocked { navigationState?.hideNotes() }
            }
    }
}
