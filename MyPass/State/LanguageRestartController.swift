import AppKit

/// Starts a fresh copy of the app. A protocol so tests never open a real application.
protocol ApplicationLaunching {
    func launchNewInstance(bundleURL: URL, completion: @escaping (Error?) -> Void)
}

struct WorkspaceApplicationLauncher: ApplicationLaunching {
    func launchNewInstance(bundleURL: URL, completion: @escaping (Error?) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        // Without this LaunchServices only re-activates the running copy and nothing restarts.
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, error in
            completion(error)
        }
    }
}

/// "Restart Now" for the language change.
///
/// The controller NEVER terminates the process. It stores the override and launches a second
/// copy of the app; that copy goes through the normal single-instance election
/// (`AppLauncher` -> `SingleInstanceCoordinator`), the newer launch wins, and the running copy
/// is asked to quit through `AppDelegate.requestTermination` -> `QuitFlushCoordinator`, so the
/// vault's queued writes are flushed (or the user is asked via the Cancel / Quit Anyway prompt)
/// before the old process exits. If the user cancels that prompt the old copy keeps running and
/// the new launch is told it was declined (it shows its alert and exits), so a cancelled quit
/// never leaves two instances behind.
@MainActor
final class LanguageRestartController: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// A new copy was launched; the old one is on its way out (or the user cancelled its
        /// save prompt, in which case this falls back to `.idle` after `resetDelay`).
        case restarting
        /// The new copy could not be launched; the user has to quit and reopen by hand.
        case manualRestartNeeded
    }

    @Published private(set) var phase: Phase = .idle

    private let launcher: ApplicationLaunching
    private let bundleURL: URL
    private let resetDelay: TimeInterval
    private var resetTask: Task<Void, Never>?

    init(
        launcher: ApplicationLaunching = WorkspaceApplicationLauncher(),
        bundleURL: URL = Bundle.main.bundleURL,
        resetDelay: TimeInterval = 30
    ) {
        self.launcher = launcher
        self.bundleURL = bundleURL
        self.resetDelay = resetDelay
    }

    /// The override is stored FIRST: the new copy reads `AppleLanguages` the moment it starts,
    /// which can be before this call returns.
    func restartNow(selecting language: AppLanguage, store: AppLanguageStore) {
        store.select(language)
        resetTask?.cancel()
        launcher.launchNewInstance(bundleURL: bundleURL) { [weak self] error in
            // NSWorkspace calls back on an arbitrary queue.
            Task { @MainActor in self?.launchFinished(error: error) }
        }
    }

    /// Call when the language picker changes. `.manualRestartNeeded` describes a failed launch
    /// for the previous choice and would otherwise stick for the rest of the session: it hides
    /// "Restart Now" and keeps the manual text even after the user switches back to the running
    /// language. A restart already in progress (`.restarting`) is left alone; it resets itself
    /// after `resetDelay`, and clearing it early would re-enable a second launch.
    func languageSelectionChanged() {
        guard phase == .manualRestartNeeded else { return }
        phase = .idle
    }

    private func launchFinished(error: Error?) {
        guard error == nil else {
            phase = .manualRestartNeeded
            return
        }
        phase = .restarting
        resetTask?.cancel()
        let delay = resetDelay
        resetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.phase = .idle
        }
    }
}
