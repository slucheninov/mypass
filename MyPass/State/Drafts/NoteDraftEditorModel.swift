import Combine
import Foundation

/// Per-editor draft state shared by `NotesEditView` and `EntryEditView`: the autosave
/// controller, the recovery banner's draft, the versions list and the pending restore.
@MainActor
final class NoteDraftEditorModel: ObservableObject {
    let controller: NoteDraftController
    @Published private(set) var pendingDraft: NoteDraftVersion?
    @Published private(set) var versions: [NoteDraftVersion]
    /// Emits the text the editor must load through the undoable `.replaceAll` command.
    /// A subject, not a @Published value read through a Binding: the card subscribes to it
    /// directly, so no parent re-render is needed for a restore to reach the editor.
    let restoreRequests = PassthroughSubject<String, Never>()
    @Published var showsVersions = false

    private let store: NoteDraftStore
    private let vaultID: String
    private let entryID: UUID

    /// - Parameter entryLastModified: nil for a new, never-saved entry (any draft is newer).
    init(store: NoteDraftStore, vaultID: String, entryID: UUID, savedNotes: String, entryLastModified: Date?) {
        self.store = store
        self.vaultID = vaultID
        self.entryID = entryID
        controller = NoteDraftController(store: store, vaultID: vaultID, entryID: entryID, baselineNotes: savedNotes)
        let all = store.versions(vaultID: vaultID, entryID: entryID)
        versions = all
        pendingDraft = NoteDraftRecovery.pendingDraft(
            versions: all, savedNotes: savedNotes, entryLastModified: entryLastModified ?? .distantPast)
        controller.attachLifecycleObservers()
    }

    func restore(_ version: NoteDraftVersion) {
        restoreRequests.send(version.notes)
        pendingDraft = nil
        showsVersions = false
    }

    func deleteDrafts() {
        store.deleteAll(vaultID: vaultID, entryID: entryID)
        pendingDraft = nil
        versions = []
    }

    /// Cancel keeps the drafts so the banner can offer them next time.
    func cancel() {
        controller.flush()
    }

    /// Save: the text is in the vault now, so the drafts are obsolete.
    func discardAfterSave() {
        controller.finish()
        deleteDrafts()
    }
}
