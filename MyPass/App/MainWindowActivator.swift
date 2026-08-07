import AppKit
import SwiftUI

extension Notification.Name {
    static let requestMainWindow = Notification.Name("com.mypass.requestMainWindow")

    /// Posted when something outside the unlock screen wants the Touch ID prompt shown
    /// again — currently only the browser extension's `requestUnlock`. `UnlockView`'s
    /// own `.onAppear` auto-prompt does not re-fire when an open window is refocused.
    static let requestDeviceUnlockPrompt = Notification.Name("com.mypass.requestDeviceUnlockPrompt")
}

enum MainWindowActivator {
    static func request() {
        NSApp.activate(ignoringOtherApps: true)
        // `main` is a WindowGroup, so `openWindow(id:)` creates an ADDITIONAL window on
        // every call rather than reusing one. Posting unconditionally therefore stacked
        // up a new window per activation. Only ask for a window when there is none to
        // front.
        guard !frontExistingMainWindowIfPresent() else { return }
        NotificationCenter.default.post(name: .requestMainWindow, object: nil)
    }

    /// Whether the main window should currently sit above other applications. Held as
    /// state rather than applied once, because the window that needs it may not exist yet:
    /// a pairing code can arrive while the main window is closed, and the window the
    /// notification opens is created *after* the request to float it.
    private static var desiredFloating = false

    /// Keeps the main window above other applications while a pairing code is on screen.
    /// The code is deliberately not sent to the extension, so the user has to read it here
    /// while typing it into the browser — and a normal-level window drops behind Chrome the
    /// moment they click the input field. Reset to `.normal` as soon as the code clears, so
    /// the app does not permanently sit on top of everything.
    static func setMainWindowFloating(_ floating: Bool) {
        desiredFloating = floating
        applyDesiredFloating()
    }

    /// Re-asserts the desired level on whatever main windows exist right now. Called again
    /// from `OpenMainWindowOnDemand.onAppear` so a window created after `setMainWindowFloating`
    /// still picks the level up.
    static func applyDesiredFloating() {
        for window in NSApp.windows where isMainAppWindow(window) {
            window.level = desiredFloating ? .floating : .normal
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
                MainWindowActivator.applyDesiredFloating()
            }
    }
}
