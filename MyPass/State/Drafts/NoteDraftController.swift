import Combine
import Foundation

/// Autosave cadence for one open notes editor.
///
/// The view calls `noteTextChanged` on every edit, `tick()` from a 10 s timer, and `flush()` on
/// app resign-active, Cancel, disappear and the will-lock notification. Both `tick` and `flush`
/// write only when the latest text differs from the last text that was written (or, before the
/// first write, from the baseline the editor opened with), so an untouched editor never creates a
/// draft, and clearing all text of a non-empty note still writes the empty version.
/// Only a successful write updates `lastSavedAt` and the "last written" marker, so a failed write
/// is retried on the next tick instead of being forgotten.
@MainActor
final class NoteDraftController: ObservableObject {
    @Published private(set) var lastSavedAt: Date?

    private let store: NoteDraftStore
    private let vaultID: String
    private let entryID: UUID
    private let now: () -> Date
    private var latestText: String
    private var lastPersistedText: String

    init(store: NoteDraftStore,
         vaultID: String,
         entryID: UUID,
         baselineNotes: String,
         now: @escaping () -> Date = Date.init) {
        self.store = store
        self.vaultID = vaultID
        self.entryID = entryID
        self.now = now
        self.latestText = baselineNotes
        self.lastPersistedText = baselineNotes
    }

    /// False when the Keychain key is unavailable; the editor then works without drafts.
    var isEnabled: Bool { store.isAvailable }

    func noteTextChanged(_ text: String) {
        latestText = text
    }

    func tick() {
        writeIfChanged()
    }

    func flush() {
        writeIfChanged()
    }

    private func writeIfChanged() {
        guard latestText != lastPersistedText else { return }
        guard store.save(notes: latestText, vaultID: vaultID, entryID: entryID) else { return }
        lastPersistedText = latestText
        lastSavedAt = now()
    }
}
