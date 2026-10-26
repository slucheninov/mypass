import AppKit
import SwiftUI

/// Keep the SwiftUI action after the last main window closes. A notification heard
/// only inside that window would disappear precisely when opening settings is needed.
enum BrowserSettingsActivator {
    private static var openSettingsAction: OpenSettingsAction?
    private static var pendingRequest = false
    private static var pendingPane: SettingsPane = .browser

    static func register(_ action: OpenSettingsAction) {
        openSettingsAction = action
        if pendingRequest {
            pendingRequest = false
            request(pane: pendingPane)
        }
    }

    /// Opens Settings on `pane` (the Browser pane by default, which is what the extension
    /// pairing flow wants). When no scene has registered the action yet, the pane is remembered
    /// and the request is replayed from `register`.
    static func request(pane: SettingsPane = .browser) {
        UserDefaults.standard.set(pane.rawValue, forKey: "settingsSelectedPane")
        NSApp.activate(ignoringOtherApps: true)
        guard let openSettingsAction else {
            pendingRequest = true
            pendingPane = pane
            MainWindowActivator.request()
            return
        }
        openSettingsAction()
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
