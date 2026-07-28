import AppKit

enum MenuBarPanelDismisser {
    static func dismiss() {
        for window in NSApp.windows where isMenuBarExtraPanel(window) {
            window.resignKey()
            window.orderOut(nil)
        }
    }

    /// Inverse of MainWindowActivator.isMainAppWindow heuristics.
    private static func isMenuBarExtraPanel(_ window: NSWindow) -> Bool {
        guard window.isVisible else { return false }
        if window.styleMask.contains(.nonactivatingPanel) { return true }
        if window is NSPanel,
           !window.styleMask.contains(.titled),
           window.level.rawValue >= NSWindow.Level.floating.rawValue {
            return true
        }
        return false
    }
}
