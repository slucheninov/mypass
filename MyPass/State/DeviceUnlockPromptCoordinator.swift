import Combine
import Foundation

/// Which surface asked for a device-unlock prompt — determines both which
/// `DeviceUnlockPromptCoordinator` gate applies and whether an auth failure is shown
/// to the user (silent for `.automatic`, surfaced for `.explicit`).
enum DeviceUnlockPromptTrigger {
    /// Fired from `onAppear` or the extension's `.requestDeviceUnlockPrompt`
    /// notification — a background convenience, not something the user asked for in
    /// this exact moment, so failures stay silent.
    case automatic
    /// Fired from the user clicking the device-unlock button directly — a deliberate
    /// retry, so failures get a message instead of silence.
    case explicit
}

/// Coordinates device-unlock (Touch ID / Mac password) prompts across every surface
/// that can trigger one — `UnlockView`'s `onAppear` and its `.requestDeviceUnlockPrompt`
/// notification handler, and `MenuBarUnlockPanelView`'s `onAppear` — so at most one
/// system auth sheet is ever in flight, and the automatic (silent) prompt fires at most
/// once per locked session no matter how many times a view appears or the menu bar
/// reopens.
///
/// Deliberately a single shared instance injected via the environment, not per-view
/// `@State`: the whole bug this fixes is that per-view state cannot see what another
/// surface already did — `MenuBarExtra`'s content closure in particular is recreated
/// (state reset) on every menu open, so a `@State` flag there is useless as a
/// cross-open, cross-surface guard.
final class DeviceUnlockPromptCoordinator: ObservableObject {
    private var isPromptInFlight = false
    private var hasAutoFiredForCurrentLockedSession = false
    private var cancellables = Set<AnyCancellable>()

    /// `vaultSession` is optional purely so unit tests can exercise the decision logic
    /// in isolation, the same way `nil` is a valid, no-op state for other injectable
    /// dependencies in this codebase. In the app, `MyPassApp` always supplies one so
    /// `vaultDidLock()` fires automatically on every lock transition.
    init(vaultSession: VaultSession? = nil) {
        guard let vaultSession else { return }
        vaultSession.$state
            .sink { [weak self] state in
                guard case .locked = state else { return }
                self?.vaultDidLock()
            }
            .store(in: &cancellables)
    }

    /// Call when the vault transitions to locked, so the next locked session gets its
    /// own fresh auto-prompt allowance. Unlocking and re-locking must allow a new
    /// automatic prompt, so this is the reset point for that.
    func vaultDidLock() {
        hasAutoFiredForCurrentLockedSession = false
        isPromptInFlight = false
    }

    /// Automatic (silent) prompt, requested from an `onAppear` or from the extension's
    /// `.requestDeviceUnlockPrompt` notification. Returns whether the caller may
    /// proceed and actually show the system sheet — `false` means either a prompt is
    /// already in flight, or one already auto-fired for this locked session, and the
    /// caller must not start another.
    func requestAutoPrompt() -> Bool {
        guard !isPromptInFlight, !hasAutoFiredForCurrentLockedSession else { return false }
        isPromptInFlight = true
        hasAutoFiredForCurrentLockedSession = true
        return true
    }

    /// Explicit prompt from a user clicking the unlock button — a deliberate retry,
    /// so it is always allowed except while a prompt is literally in flight.
    func requestExplicitPrompt() -> Bool {
        guard !isPromptInFlight else { return false }
        isPromptInFlight = true
        return true
    }

    /// Call from the `DeviceUnlockAuthenticator.authenticate` completion — success,
    /// failure, or cancellation — so the next prompt (auto or explicit) is no longer
    /// blocked by this one.
    func promptFinished() {
        isPromptInFlight = false
    }
}
