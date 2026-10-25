import Foundation

/// Gate in front of every normal termination (Cmd-Q, the menu bar Quit row, a
/// takeover quit from a newer MyPass): the vault's queued and debounced writes
/// must reach disk first, even if the session has been locked in the meantime.
///
/// A failed or unfinished flush is never swallowed. The user is asked, with
/// Cancel as the default button, whether to quit anyway; there is no silent
/// loss and no force-kill.
final class QuitFlushCoordinator {
    static let defaultFlushTimeout: TimeInterval = 10

    private let session: VaultFlushing?
    private let prompter: QuitPrompting
    private let flushTimeout: TimeInterval
    private(set) var isInFlight = false

    init(session: VaultFlushing?, prompter: QuitPrompting, flushTimeout: TimeInterval = QuitFlushCoordinator.defaultFlushTimeout) {
        self.session = session
        self.prompter = prompter
        self.flushTimeout = flushTimeout
    }

    enum Begin: Equatable {
        /// Nothing to wait for; terminate immediately.
        case terminateNow
        /// `reply` will be called exactly once, later, on the main thread.
        case terminateLater
        /// Another quit attempt is already in progress; this request is dropped.
        case alreadyInFlight
    }

    /// Runs `terminate` (normally `NSApp.terminate`) unless a flush is already in flight, and
    /// reports whether it ran. Every caller that terminates the app by itself (the menu bar Quit
    /// row, the takeover request) goes through here, because a SECOND `NSApp.terminate` while a
    /// `terminateLater` is pending does not consult the delegate again: AppKit terminates
    /// straight away and the pending save-flush never completes (measured with an isolated
    /// AppKit probe: `willTerminate` fires at once, `applicationShouldTerminate` is not called).
    /// The pending quit is already on its way, so dropping the duplicate loses nothing.
    @discardableResult
    func requestTermination(_ terminate: () -> Void) -> Bool {
        guard !isInFlight else { return false }
        terminate()
        return true
    }

    /// Main thread only. `reply(true)` means "terminate", `reply(false)` means "stay running".
    func begin(reply: @escaping (Bool) -> Void) -> Begin {
        guard let session else { return .terminateNow }
        guard !isInFlight else { return .alreadyInFlight }
        isInFlight = true
        session.flushPendingWrites(timeout: flushTimeout) { [weak self] outcome in
            guard let self else { return reply(true) }
            switch outcome {
            case .flushed:
                self.isInFlight = false
                reply(true)
            case .saveFailed, .timedOut:
                self.prompter.confirmQuitAnyway(after: outcome) { quitAnyway in
                    self.isInFlight = false
                    // Cancel: the app keeps running, so it must accept changes again.
                    if !quitAnyway { session.resumeAfterCancelledQuit() }
                    reply(quitAnyway)
                }
            }
        }
        return .terminateLater
    }
}

protocol QuitPrompting {
    /// Asks whether to quit even though the flush did not complete cleanly.
    /// `completion(true)` is "Quit Anyway"; the default answer is Cancel.
    func confirmQuitAnyway(after outcome: VaultFlushOutcome, completion: @escaping (Bool) -> Void)
}
