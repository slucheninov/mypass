import AppKit

struct AppKitQuitPrompter: QuitPrompting {
    /// Order matters: the first button is the default (Return), so Cancel must come first.
    /// A computed property rather than a stored constant so the titles are looked up in the
    /// string catalog each time the alert is built.
    static var buttonTitles: [String] {
        [
            String(localized: "Cancel", comment: "Quit confirmation alert: default button, keeps MyPass open"),
            String(localized: "Quit Anyway", comment: "Quit confirmation alert: quits even though the last save is unconfirmed")
        ]
    }

    func confirmQuitAnyway(after outcome: VaultFlushOutcome, completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        switch outcome {
        case .saveFailed(let detail):
            alert.messageText = String(localized: "MyPass could not confirm that your changes were saved", comment: "Quit confirmation alert title")
            alert.informativeText = String(localized: "\(detail)\n\nIf you quit now, recent changes may be lost.", comment: "Quit confirmation alert body; the argument is the technical reason the save failed")
        case .timedOut:
            alert.messageText = String(localized: "MyPass is still saving your vault", comment: "Quit confirmation alert title")
            alert.informativeText = String(localized: "The last write has not finished. If you quit now, recent changes may be lost.", comment: "Quit confirmation alert body")
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
