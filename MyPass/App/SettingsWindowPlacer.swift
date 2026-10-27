import AppKit
import SwiftUI

/// Positions the Settings window over the MyPass main window (or, with no usable main window,
/// on the display under the pointer) and keeps it on the user's current Space.
///
/// SwiftUI's `openSettings` has no placement hook and the Settings scene's `NSWindow` is created
/// lazily, so the window is identified through `SettingsWindowAccessor` (a view inside it) and
/// not by title (localized later) or by SwiftUI's private window identifier.
///
/// Every open path goes through `BrowserSettingsActivator.request`, which calls `openSettings`
/// here. That is the only way to be sure no entry point (popover, Cmd-comma, "Check for
/// Updates...", extension pairing) bypasses the placement.
@MainActor
enum SettingsWindowPlacer {
    private static weak var settingsWindow: NSWindow?
    /// Target computed before the window existed; applied from `attach` while the window is
    /// still off screen, so the first open does not flash at SwiftUI's default position.
    private static var pendingFrame: CGRect?

    /// Computes the placement, pre-positions the window when it already exists, runs `open`
    /// (the SwiftUI `openSettings` action) and re-applies once on the next run-loop turn.
    static func openSettings(_ open: () -> Void) {
        let size = settingsWindow?.frame.size ?? CGSize(width: 660, height: 420)
        let target = SettingsWindowPlacement.targetFrame(
            windowSize: size,
            anchor: MainWindowActivator.visibleMainWindowOnActiveSpace()?.frame,
            pointer: NSEvent.mouseLocation,
            screens: NSScreen.screens.map {
                SettingsWindowPlacement.Screen(frame: $0.frame, visibleFrame: $0.visibleFrame)
            }
        )

        if let window = settingsWindow {
            allowOnCurrentSpace(window)
            if let target { window.setFrame(target, display: false) }
        } else {
            pendingFrame = target
        }

        open()

        // Safety net: if SwiftUI restored a saved frame or re-laid the window out while
        // handling `open()`, put it back. Setting the same frame twice is harmless.
        DispatchQueue.main.async {
            guard let window = settingsWindow, let target else { return }
            if window.frame != target { window.setFrame(target, display: false) }
        }
    }

    /// Called by `SettingsWindowAccessor` once the Settings window exists.
    static func attach(_ window: NSWindow) {
        settingsWindow = window
        allowOnCurrentSpace(window)
        if let frame = pendingFrame {
            pendingFrame = nil
            window.setFrame(frame, display: false)
        }
    }

    /// `.moveToActiveSpace` makes the window follow the user to the current Space instead of
    /// pulling them back to the Space where Settings was last shown.
    private static func allowOnCurrentSpace(_ window: NSWindow) {
        window.collectionBehavior.insert(.moveToActiveSpace)
    }
}

/// Reports the hosting `NSWindow` of the view it is attached to to `SettingsWindowPlacer`.
struct SettingsWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        AccessorView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class AccessorView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            Task { @MainActor in SettingsWindowPlacer.attach(window) }
        }
    }
}
