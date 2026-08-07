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
        frontExistingMainWindowIfPresent()
        NotificationCenter.default.post(name: .requestMainWindow, object: nil)
    }

    private static func frontExistingMainWindowIfPresent() {
        for window in NSApp.windows where isMainAppWindow(window) {
            window.makeKeyAndOrderFront(nil)
            return
        }
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
