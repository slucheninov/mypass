import AppKit
import os.log

/// Process entry point. It runs BEFORE `MyPassApp.init`, so a launch that does
/// not win the single-instance election never touches `UserDefaults`, the
/// Keychain, the loopback bridge, the vault, or any timer. Only the owner goes
/// on to `MyPassApp.main()`.
///
/// Hosted XCTest runs and SwiftUI previews skip the election entirely: they do
/// not take the lock, send nothing, and listen to nothing, so merely appearing
/// can never make the user's running MyPass quit.
@main
enum AppLauncher {
    enum Mode: Equatable {
        case inertTestOrPreviewHost
        case guarded
    }

    static func mode(isTestOrPreviewHost: Bool) -> Mode {
        isTestOrPreviewHost ? .inertTestOrPreviewHost : .guarded
    }

    static func main() {
        guard mode(isTestOrPreviewHost: AppRuntimeEnvironment.isTestOrPreviewHost) == .guarded else {
            MyPassApp.main()
            return
        }

        // Creating the NSApplication registers this process with LaunchServices,
        // which is what lets a concurrent launch see it; a direct-exec process
        // is invisible to `runningApplications` until then. No window, no vault
        // and no UI exist yet.
        _ = NSApplication.shared

        let lockDirectory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyPass")
        let coordinator = SingleInstanceCoordinator(
            host: AppKitSingleInstanceHost(),
            tryLock: {
                switch InstanceLock.tryAcquire(directory: lockDirectory) {
                case .acquired(let lock): return .acquired(lock)
                case .held: return .held
                case .failed(let detail): return .failed(detail)
                }
            },
            // Scheduled as a run-loop block instead of called inline: a `terminateLater`
            // waiting in a nested loop must not sit inside a notification callback (the
            // coordinator also only gets here while the request is still live). It goes
            // through `AppDelegate.requestTermination`, which drops a duplicate request
            // while a flush is in flight: AppKit does not consult the delegate for a
            // second `NSApp.terminate` and would terminate at once, skipping the flush.
            requestQuit: { RunLoop.main.perform(inModes: [.common]) { AppDelegate.requestTermination() } },
            // A failed launch keeps answering probes while its message is on screen
            // (so it never blocks a later launch); a newer launch's commit tells it to go.
            abandonWhileInactive: { exit(EXIT_SUCCESS) }
        )

        switch coordinator.acquire() {
        case .owner:
            AppDelegate.singleInstance = coordinator
            MyPassApp.main()
        case .yielded:
            exit(EXIT_SUCCESS)
        case .failed(let failure):
            os_log(
                "Single-instance guard refused to start: %{public}@",
                log: OSLog(subsystem: "com.mypass.app", category: "SingleInstance"),
                type: .error,
                String(describing: failure)
            )
            // `coordinator` stays alive (and listening, as an inactive loser) while the
            // modal message is up; it holds no vault, bridge or lock.
            present(failure)
            withExtendedLifetime(coordinator) { exit(EXIT_FAILURE) }
        }
    }

    private static func present(_ failure: SingleInstanceFailure) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = failure.title
        alert.informativeText = failure.message
        alert.addButton(withTitle: "Quit")
        alert.runModal()
    }
}
