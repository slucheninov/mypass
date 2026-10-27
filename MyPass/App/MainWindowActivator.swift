import AppKit
import SwiftUI

extension Notification.Name {
    static let requestMainWindow = Notification.Name("com.mypass.requestMainWindow")

    /// Posted when something outside the unlock screen wants the Touch ID prompt shown
    /// — currently only the browser extension's `requestUnlock`. `UnlockView` never
    /// prompts on its own when it appears or an open window is refocused; this
    /// notification (paired with `DeviceUnlockPromptCoordinator`'s recorded extension
    /// request, which `UnlockView.onAppear` consumes when the window was closed) is the
    /// only non-button path to a prompt.
    static let requestDeviceUnlockPrompt = Notification.Name("com.mypass.requestDeviceUnlockPrompt")
}

enum MainWindowActivator {
    /// SwiftUI's window-opening action, captured while a window exists so it can still be
    /// used after the last one closes. `OpenMainWindowOnDemand` lives inside the very
    /// `WindowGroup` it opens, so with the window closed there is no view left to receive
    /// the notification — the request simply vanished and no window ever appeared.
    private static var openWindowAction: OpenWindowAction?

    static func registerOpenWindowAction(_ action: OpenWindowAction) {
        openWindowAction = action
    }

    static func request() {
        NSApp.activate(ignoringOtherApps: true)
        // `main` is a WindowGroup, so `openWindow(id:)` creates an ADDITIONAL window on
        // every call rather than reusing one. Posting unconditionally therefore stacked
        // up a new window per activation. Only ask for a window when there is none to
        // front.
        guard !frontExistingMainWindowIfPresent() else { return }
        // Call the captured action directly: the notification is only heard by a view
        // inside the window, which is exactly what is missing here.
        if let openWindowAction {
            openWindowAction(id: "main")
        } else {
            NotificationCenter.default.post(name: .requestMainWindow, object: nil)
        }
    }

    /// Whether the main window should currently sit above other applications. Held as
    /// state rather than applied once, because the window that needs it may not exist yet:
    /// a pairing code can arrive while the main window is closed, and the window opened in
    /// response is created *after* the request to float it.
    private static var desiredFloating = false
    private static var floatingKeepAlive: Timer?
    private static var floatingObserver: Any?

    /// Keeps the main window above other applications while a pairing code is on screen.
    /// The code is deliberately not sent to the extension, so the user has to read it here
    /// while typing it into the browser — and a normal-level window drops behind Chrome the
    /// moment they click the input field. Reset to `.normal` as soon as the code clears, so
    /// the app does not permanently sit on top of everything.
    static func setMainWindowFloating(_ floating: Bool) {
        desiredFloating = floating
        applyDesiredFloating()

        // Applying once is not enough when the main window is closed: the pairing code
        // arrives, we float an empty window list, and the window the notification opens is
        // created afterwards at `.normal`.
        //
        // Measured, not assumed: with the window already open, one apply is sufficient —
        // instrumentation showed the level was never clobbered for the whole time a code
        // was on screen. The keep-alive exists purely to catch a window that appears late.
        // `OpenMainWindowOnDemand.onAppear` should already cover that, so this is a safety
        // net rather than a proven necessity; it is kept because the failure it guards
        // against (an unreadable pairing code) is user-visible, and it costs one timer for
        // the few seconds a challenge lives. Both it and the observer are torn down the
        // moment the code clears.
        floatingKeepAlive?.invalidate()
        floatingKeepAlive = nil
        if let floatingObserver {
            NotificationCenter.default.removeObserver(floatingObserver)
            self.floatingObserver = nil
        }
        guard floating else { return }

        floatingObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { _ in applyDesiredFloating() }

        let timer = Timer(timeInterval: 0.4, repeats: true) { _ in applyDesiredFloating() }
        RunLoop.main.add(timer, forMode: .common)
        floatingKeepAlive = timer
    }

    /// Re-asserts the desired level on whatever main windows exist right now. Called again
    /// from `OpenMainWindowOnDemand.onAppear` so a window created after `setMainWindowFloating`
    /// still picks the level up.
    static func applyDesiredFloating() {
        let target: NSWindow.Level = desiredFloating ? .floating : .normal
        for window in NSApp.windows where isMainAppWindow(window) && window.level != target {
            window.level = target
        }
    }

    /// Returns `true` when an existing main window was found and brought forward.
    private static func frontExistingMainWindowIfPresent() -> Bool {
        for window in NSApp.windows where isMainAppWindow(window) {
            window.makeKeyAndOrderFront(nil)
            return true
        }
        return false
    }

    /// The main window the user can actually see right now: visible, not minimized and on the
    /// Space being displayed. `SettingsWindowPlacer` centres Settings over it; `nil` makes the
    /// placer fall back to the display under the pointer.
    static func visibleMainWindowOnActiveSpace() -> NSWindow? {
        NSApp.windows.first {
            isMainAppWindow($0) && $0.isVisible && !$0.isMiniaturized && $0.isOnActiveSpace
        }
    }

    private static func isMainAppWindow(_ window: NSWindow) -> Bool {
        // Deliberately does NOT test the window level. It used to require `.normal`, which
        // made the whole helper blind to its own main window the moment it was floated:
        // the level could never be reset, `request()` stopped finding the window and opened
        // another, and a freshly created window never picked the level up. The menu-bar
        // panel is already excluded by requiring `.titled` and rejecting `.nonactivatingPanel`
        // — see MenuBarPanelDismisser, whose panel heuristic requires `!titled`.
        guard window.styleMask.contains(.titled) else { return false }
        guard !window.styleMask.contains(.nonactivatingPanel) else { return false }
        return window.canBecomeMain || window.isMainWindow
    }
}

struct OpenMainWindowOnDemand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(NotificationCenter.default.publisher(for: .requestMainWindow)) { _ in
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }
            .onAppear {
                // This view is created with each main window, so it is the one place that
                // reliably runs *after* a window exists. Without it, a window opened in
                // response to a pairing code never receives the floating level.
                MainWindowActivator.registerOpenWindowAction(openWindow)
                MainWindowActivator.applyDesiredFloating()
            }
    }
}
