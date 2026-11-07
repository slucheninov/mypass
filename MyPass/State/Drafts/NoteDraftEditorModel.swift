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
    /// The entry the editor saves under. A create editor that adopts an orphaned draft
    /// switches to the orphan's ID, so autosave and the final Save use it.
    private(set) var entryID: UUID
    /// Whose drafts the banner is offering: `entryID` itself, or an orphan's entry.
    private var offeredEntryID: UUID

    /// - Parameter entryLastModified: nil for a new, never-saved entry (any draft is newer).
    /// - Parameter databaseEntryIDs: non-nil in create mode: every entry ID in the open
    ///   database. Drafts of entries absent from it are orphans (never saved) and the newest
    ///   is offered for recovery.
    init(store: NoteDraftStore, vaultID: String, entryID: UUID, savedNotes: String,
         entryLastModified: Date?, databaseEntryIDs: Set<UUID>? = nil) {
        self.store = store
        self.vaultID = vaultID
        self.entryID = entryID
        self.offeredEntryID = entryID
        controller = NoteDraftController(store: store, vaultID: vaultID, entryID: entryID, baselineNotes: savedNotes)
        let all = store.versions(vaultID: vaultID, entryID: entryID)
        versions = all
        pendingDraft = NoteDraftRecovery.pendingDraft(
            versions: all, savedNotes: savedNotes, entryLastModified: entryLastModified ?? .distantPast)
        if pendingDraft == nil, let known = databaseEntryIDs {
            let candidates = store.draftEntryIDs(vaultID: vaultID)
                .filter { $0 != entryID }
                .map { (entryID: $0, versions: store.versions(vaultID: vaultID, entryID: $0)) }
            if let orphan = NoteDraftRecovery.newestOrphan(candidates: candidates, databaseEntryIDs: known) {
                offeredEntryID = orphan.entryID
                versions = candidates.first { $0.entryID == orphan.entryID }?.versions ?? []
                pendingDraft = NoteDraftRecovery.pendingDraft(
                    versions: versions, savedNotes: savedNotes, entryLastModified: .distantPast)
            }
        }
        controller.attachLifecycleObservers()
    }

    func restore(_ version: NoteDraftVersion) {
        if offeredEntryID != entryID {
            entryID = offeredEntryID
            controller.adopt(entryID: offeredEntryID)
        }
        restoreRequests.send(version.notes)
        pendingDraft = nil
        showsVersions = false
    }

    /// Banner Delete: removes the drafts on offer (an orphan's, or this entry's).
    func deleteDrafts() {
        store.deleteAll(vaultID: vaultID, entryID: offeredEntryID)
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
        store.deleteAll(vaultID: vaultID, entryID: entryID)
        pendingDraft = nil
        versions = []
        NotificationCenter.default.post(name: .noteDraftsDiscarded, object: nil, userInfo: ["entryID": entryID])
    }
}
