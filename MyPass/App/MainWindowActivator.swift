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

    /// Keeps the main window above other applications while a pairing code is on screen.
    /// The code is deliberately not sent to the extension, so the user has to read it here
    /// while typing it into the browser — and a normal-level window drops behind Chrome the
    /// moment they click the input field. Reset to `.normal` as soon as the code clears, so
    /// the app does not permanently sit on top of everything.
    static func setMainWindowFloating(_ floating: Bool) {
        for window in NSApp.windows where isMainAppWindow(window) {
            window.level = floating ? .floating : .normal
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
        guard window.level == .normal else { return false }
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
    }
}
