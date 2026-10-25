import AppKit

struct AppKitQuitPrompter: QuitPrompting {
    /// Order matters: the first button is the default (Return), so Cancel must come first.
    static let buttonTitles = ["Cancel", "Quit Anyway"]

    func confirmQuitAnyway(after outcome: VaultFlushOutcome, completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        switch outcome {
        case .saveFailed(let detail):
            alert.messageText = "MyPass could not confirm that your changes were saved"
            alert.informativeText = "\(detail)\n\nIf you quit now, recent changes may be lost."
        case .timedOut:
            alert.messageText = "MyPass is still saving your vault"
            alert.informativeText = "The last write has not finished. If you quit now, recent changes may be lost."
        case .flushed:
            completion(true)
            return
        }
        // The first button is the default (Return). Cancel is deliberately it.
        Self.buttonTitles.forEach { alert.addButton(withTitle: $0) }
        NSApp.activate(ignoringOtherApps: true)
        completion(alert.runModal() == .alertSecondButtonReturn)
    }
}
