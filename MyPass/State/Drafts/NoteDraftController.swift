import AppKit
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
    private var entryID: UUID
    private let now: () -> Date
    private var latestText: String
    private var lastPersistedText: String
    /// Set after Save: the draft was deleted and the disappearing editor must not recreate it.
    private var isFinished = false
    private var observers: ObserverBag?

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

    /// Flushes on the will-lock notification and on app resign-active. `center` is injectable so
    /// tests use a private one. Calling it again replaces the previous registration.
    func attachLifecycleObservers(center: NotificationCenter = .default) {
        let bag = ObserverBag()
        bag.center = center
        // queue nil: the block runs synchronously on the posting thread, which is what
        // `VaultSession.lock()` needs (the flush must finish before the store is locked).
        // Both notifications are posted on the main thread.
        // willTerminate: Cmd-Q does not reliably run onDisappear or post resign-active first.
        for name in [Notification.Name.vaultWillLock, NSApplication.didResignActiveNotification,
                     NSApplication.willTerminateNotification] {
            bag.tokens.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.flush() }
            })
        }
        // Another window saved or permanently deleted this entry: its drafts are gone and this
        // editor must not write them back.
        bag.tokens.append(center.addObserver(forName: .noteDraftsDiscarded, object: nil, queue: nil) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, note.userInfo?["entryID"] as? UUID == self.entryID else { return }
                self.finish()
            }
        })
        observers = bag
    }

    /// Re-targets autosave at an orphaned draft's entry (create editor adopting a recovered draft).
    func adopt(entryID newID: UUID) {
        entryID = newID
    }

    /// Stops all writing for good (after Save has deleted the drafts).
    func finish() {
        isFinished = true
    }

    func tick() {
        writeIfChanged()
    }

    func flush() {
        writeIfChanged()
    }

    private func writeIfChanged() {
        guard !isFinished, latestText != lastPersistedText else { return }
        guard store.save(notes: latestText, vaultID: vaultID, entryID: entryID) else { return }
        lastPersistedText = latestText
        lastSavedAt = now()
    }
}

extension Notification.Name {
    /// Drafts of `userInfo["entryID"]` were deleted for good (Save, permanent delete).
    static let noteDraftsDiscarded = Notification.Name("com.mypass.noteDraftsDiscarded")
}

/// Removes the notification observers when the controller goes away.
private final class ObserverBag {
    var center: NotificationCenter?
    var tokens: [NSObjectProtocol] = []
    deinit { tokens.forEach { center?.removeObserver($0) } }
}
