import Combine
import Foundation

/// Coordinates device-unlock (Touch ID / Mac password) prompts across every surface
/// that can trigger one — `UnlockView` and `MenuBarUnlockPanelView` — so at most one
/// system auth sheet is ever in flight.
///
/// A device-unlock prompt is only ever explicit: a press of the "Unlock with Device"
/// button, or the browser extension's Unlock button (which is itself a deliberate user
/// action). Nothing fires one merely because a view appeared, the vault locked, or a
/// window gained focus. The coordinator therefore no longer carries any "automatic
/// prompt once per locked session" state; it only serialises explicit prompts.
///
/// It also remembers a pending extension unlock request. The extension's Unlock arrives
/// on the bridge while `UnlockView` may not be mounted yet (the main window was closed
/// and `MainWindowActivator.request()` opens it asynchronously), so a notification
/// alone would be dropped. `noteExtensionUnlockRequest()` records the request and
/// whichever path reaches the view first — the notification handler (window already
/// open) or `onAppear` (window just opened) — calls `consumeExtensionUnlockRequest()`;
/// the first consumer wins, so exactly one prompt is shown. A plain view appearance with
/// no extension request pending consumes nothing and shows no prompt.
///
/// Deliberately a single shared instance injected via the environment, not per-view
/// `@State`: per-view state cannot see what another surface already did —
/// `MenuBarExtra`'s content closure in particular is recreated (state reset) on every
/// menu open, so a `@State` flag there is useless as a cross-open, cross-surface guard.
///
/// `@MainActor` because every caller (SwiftUI views, `DeviceUnlockAuthenticator`
/// completions already dispatched onto the main queue) already runs there, and this
/// type has no business being touched off it.
@MainActor
final class DeviceUnlockPromptCoordinator: ObservableObject {
    /// An in-flight prompt older than this is treated as abandoned and self-heals as
    /// if `promptFinished()` had been called. Guards against `LAContext`'s completion
    /// handler simply never arriving (the system dialog dismissed in a way that drops
    /// the callback, the process losing focus, etc.) permanently wedging the explicit
    /// gate for the rest of the locked session.
    static let staleInFlightThreshold: TimeInterval = 60

    /// How long a recorded extension unlock request stays valid. Long enough to cover
    /// the main window opening and `UnlockView` mounting after the extension's Unlock
    /// arrives; short enough that a request nobody consumed (vault unlocked another way,
    /// no unlock screen shown) cannot trigger a surprise prompt much later.
    static let extensionRequestFreshness: TimeInterval = 10

    private let now: () -> Date
    private var isPromptInFlight = false
    private var promptStartedAt: Date?
    private var extensionRequestedAt: Date?
    private var cancellables = Set<AnyCancellable>()

    /// `vaultSession` is optional purely so unit tests can exercise the decision logic
    /// in isolation, the same way `nil` is a valid, no-op state for other injectable
    /// dependencies in this codebase. In the app, `MyPassApp` always supplies one so
    /// `vaultDidLock()` fires automatically on every lock transition.
    ///
    /// `now` is injectable, matching `ExtensionBridgeService`'s debounce clock, so the
    /// staleness check is testable without sleeping 60 real seconds.
    init(vaultSession: VaultSession? = nil, now: @escaping () -> Date = Date.init) {
        self.now = now
        guard let vaultSession else { return }
        vaultSession.$state
            .sink { [weak self] state in
                switch state {
                case .locked:
                    self?.vaultDidLock()
                case .unlocked:
                    // An extension Unlock request that was never consumed (device unlock
                    // was unavailable, so `UnlockView` skipped it) must not survive the
                    // vault being unlocked by other means: a Lock within the freshness
                    // window would otherwise find it still valid and pop a Touch ID
                    // sheet nobody asked for. Cleared here, not in `vaultDidLock()`:
                    // `$state` can republish `.locked`, which would wipe a request that
                    // is still valid for the unlock screen about to appear.
                    self?.extensionRequestedAt = nil
                }
            }
            .store(in: &cancellables)
    }

    /// `isPromptInFlight`, but self-healing: a prompt started more than
    /// `staleInFlightThreshold` ago is treated as finished, clearing the stuck state
    /// as a side effect so a later caller doesn't pay the same staleness check again.
    private var isPromptEffectivelyInFlight: Bool {
        guard isPromptInFlight else { return false }
        guard let promptStartedAt, now().timeIntervalSince(promptStartedAt) < Self.staleInFlightThreshold else {
            isPromptInFlight = false
            self.promptStartedAt = nil
            return false
        }
        return true
    }

    /// Call when the vault transitions to locked. Only clears the in-flight state: a
    /// lock neither grants nor forbids a prompt, and it deliberately does not create an
    /// extension request, so locking can never cause a Touch ID sheet by itself.
    func vaultDidLock() {
        isPromptInFlight = false
        promptStartedAt = nil
    }

    /// Explicit prompt, from the user pressing an unlock button or from a consumed
    /// extension unlock request. Always allowed except while a prompt is literally in
    /// flight; `false` means the caller must not start another system sheet.
    func requestExplicitPrompt() -> Bool {
        guard !isPromptEffectivelyInFlight else { return false }
        isPromptInFlight = true
        promptStartedAt = now()
        return true
    }

    /// Call from the `DeviceUnlockAuthenticator.authenticate` completion — success,
    /// failure, or cancellation — so the next prompt is no longer blocked by this one.
    func promptFinished() {
        isPromptInFlight = false
        promptStartedAt = nil
    }

    /// Records that the browser extension's Unlock button was pressed. Called from
    /// `MyPassApp.onUnlockRequested` before the main window is raised, so the request
    /// is already waiting when `UnlockView` appears (window was closed) or when its
    /// notification handler runs (window already open).
    func noteExtensionUnlockRequest() {
        extensionRequestedAt = now()
    }

    /// Returns `true` at most once per `noteExtensionUnlockRequest()`, and only while
    /// the request is younger than `extensionRequestFreshness`. A stale request is
    /// cleared and reported as `false`. With nothing recorded (the plain-appearance
    /// case) it returns `false`, which is what keeps `onAppear` from ever prompting.
    func consumeExtensionUnlockRequest() -> Bool {
        guard let requestedAt = extensionRequestedAt else { return false }
        extensionRequestedAt = nil
        return now().timeIntervalSince(requestedAt) < Self.extensionRequestFreshness
    }
}
