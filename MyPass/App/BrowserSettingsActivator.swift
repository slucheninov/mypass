import AppKit
import SwiftUI

/// The single funnel that opens the Settings window. Every entry point (menu bar popover,
/// Cmd-comma, "Check for Updates...", extension pairing) calls `request`, so the window is always
/// placed by `SettingsWindowPlacer` and none of them can bypass it.
///
/// Also keeps the SwiftUI action after the last main window closes. A notification heard
/// only inside that window would disappear precisely when opening settings is needed.
@MainActor
enum BrowserSettingsActivator {
    /// The pane the extension pairing flow wants.
    static let defaultPane: SettingsPane = .browser

    private static var openSettingsAction: OpenSettingsAction?
    private static var pendingRequest = false
    private static var pendingPane: SettingsPane?

    static func register(_ action: OpenSettingsAction) {
        openSettingsAction = action
        if pendingRequest {
            pendingRequest = false
            let pane = pendingPane
            pendingPane = nil
            request(pane: pane)
        }
    }

    /// Opens Settings on `pane` (the Browser pane by default, which is what the extension
    /// pairing flow wants); `nil` keeps the last selected pane (popover, Cmd-comma). When no
    /// scene has registered the action yet, the pane is remembered and the request is replayed
    /// from `register`.
    static func request(pane: SettingsPane? = defaultPane, defaults: UserDefaults = .standard) {
        recordRequestedPane(pane, in: defaults)
        NSApp.activate(ignoringOtherApps: true)
        guard let openSettingsAction else {
            pendingRequest = true
            pendingPane = pane
            MainWindowActivator.request()
            return
        }
        SettingsWindowPlacer.openSettings { openSettingsAction() }
    }

    /// Stores the pane the Settings window should show; `nil` leaves the stored selection alone.
    static func recordRequestedPane(_ pane: SettingsPane?, in defaults: UserDefaults) {
        guard let pane else { return }
        defaults.set(pane.rawValue, forKey: "settingsSelectedPane")
    }
}

struct OpenBrowserSettingsOnDemand: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { BrowserSettingsActivator.register(openSettings) }
    }
}
