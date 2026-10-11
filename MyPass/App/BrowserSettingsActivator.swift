import AppKit
import SwiftUI

/// Keep the SwiftUI action after the last main window closes. A notification heard
/// only inside that window would disappear precisely when opening settings is needed.
enum BrowserSettingsActivator {
    private static var openSettingsAction: OpenSettingsAction?
    private static var pendingRequest = false

    static func register(_ action: OpenSettingsAction) {
        openSettingsAction = action
        if pendingRequest {
            pendingRequest = false
            request()
        }
    }

    static func request() {
        UserDefaults.standard.set(SettingsPane.browser.rawValue, forKey: "settingsSelectedPane")
        NSApp.activate(ignoringOtherApps: true)
        guard let openSettingsAction else {
            pendingRequest = true
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
