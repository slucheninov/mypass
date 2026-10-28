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

    /// The inputs of a placement, captured at the moment Settings was requested. They are kept
    /// instead of a ready-made frame because the frame depends on the window's size, which is
    /// only known once the window exists: 660x420 is merely the minimum, and SwiftUI may size
    /// the window larger or restore a saved size. The size is never changed, only the origin.
    private struct Request {
        let anchor: CGRect?
        let pointer: CGPoint
        let screens: [SettingsWindowPlacement.Screen]

        func frame(for size: CGSize) -> CGRect? {
            SettingsWindowPlacement.targetFrame(
                windowSize: size, anchor: anchor, pointer: pointer, screens: screens)
        }
    }

    /// Request made before the window existed; applied from `attach` while the window is still
    /// off screen. Cleared by the safety net in `openSettings` so it cannot go stale when
    /// `open()` never creates the window.
    private static var pendingRequest: Request?

    /// Computes the placement, pre-positions the window when it already exists, runs `open`
    /// (the SwiftUI `openSettings` action) and re-applies once on the next run-loop turn.
    static func openSettings(_ open: () -> Void) {
        let request = Request(
            // The Settings window itself is excluded: it is titled and can become main, so
            // with the main window closed or minimized it would otherwise anchor to itself
            // and never move to the display under the pointer.
            anchor: MainWindowActivator.visibleMainWindowOnActiveSpace(excluding: settingsWindow)?.frame,
            pointer: NSEvent.mouseLocation,
            screens: NSScreen.screens.map {
                SettingsWindowPlacement.Screen(frame: $0.frame, visibleFrame: $0.visibleFrame)
            }
        )

        if let window = settingsWindow {
            allowOnCurrentSpace(window)
            place(window, using: request)
        } else {
            pendingRequest = request
        }

        open()

        // Safety net: if SwiftUI restored a saved position or re-laid the window out while
        // handling `open()`, put it back. Re-placing with the same inputs is idempotent.
        DispatchQueue.main.async {
            pendingRequest = nil
            if let window = settingsWindow { place(window, using: request) }
        }
    }

    /// Called by `SettingsWindowAccessor` once the Settings window exists.
    static func attach(_ window: NSWindow) {
        settingsWindow = window
        allowOnCurrentSpace(window)
        if let request = pendingRequest {
            pendingRequest = nil
            place(window, using: request)
        }
    }

    /// Moves the window to the target origin computed for its *current* size; never resizes.
    private static func place(_ window: NSWindow, using request: Request) {
        guard let target = request.frame(for: window.frame.size),
              target.origin != window.frame.origin else { return }
        window.setFrameOrigin(target.origin)
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
            // Synchronous on purpose: deferring would let the window be ordered front at
            // SwiftUI's default position first, which is exactly the flash `attach` avoids.
            // AppKit calls this on the main thread.
            MainActor.assumeIsolated { SettingsWindowPlacer.attach(window) }
        }
    }
}
