import Combine
import Foundation
import ExtensionBridgeKit

struct BrowserDiagnosticsSnapshot: Equatable {
    let report: BrowserDiagnosticsReport
    let receivedAt: Date

    // The three status lines below are computed UI text shown with `Text(String)`, which never
    // looks anything up in the string catalog, so each one is built with `String(localized:)`.
    // They stay `String` (not `LocalizedStringResource`) because the tests assert on the text.
    var passkeyStatus: String {
        switch report.proxyState {
        case .active: return String(localized: "MyPass was ready to receive passkey requests at the last check.", comment: "Browser settings: passkey status line")
        case .disabled: return String(localized: "MyPass passkeys were turned off at the last check.", comment: "Browser settings: passkey status line")
        case .locked: return String(localized: "Unlock MyPass, then reopen its browser extension.", comment: "Browser settings: passkey status line")
        case .unpaired: return String(localized: "Connect this browser to MyPass again.", comment: "Browser settings: passkey status line")
        case .unavailable: return String(localized: "Open MyPass and reopen its browser extension to check passkeys.", comment: "Browser settings: passkey status line")
        case .attachmentError: return String(localized: "MyPass could not handle passkeys. Disable other passkey extensions, then check again.", comment: "Browser settings: passkey status line")
        }
    }

    var passwordSavingStatus: String {
        switch report.passwordSavingEnabled {
        case true: return String(localized: "Browser password saving: on", comment: "Browser settings: browser built-in password saving status")
        case false: return String(localized: "Browser password saving: off", comment: "Browser settings: browser built-in password saving status")
        case nil: return String(localized: "Browser password saving: unknown", comment: "Browser settings: browser built-in password saving status")
        }
    }

    var managerStatus: String {
        switch report.permissionState {
        case .notGranted: return String(localized: "Check not allowed yet. In the MyPass extension, choose Check this browser and allow the check.", comment: "Browser settings: competing password manager check status")
        case .unavailable: return String(localized: "Browser check permission could not be read. Reopen the extension and try again.", comment: "Browser settings: competing password manager check status")
        case .granted:
            switch report.extensionScanState {
            case .notChecked: return String(localized: "Extension check has not run. Choose Check this browser in the MyPass extension.", comment: "Browser settings: competing password manager check status")
            case .unavailable: return String(localized: "Installed extensions could not be checked. Check them manually in your browser.", comment: "Browser settings: competing password manager check status")
            case .complete:
                // One sentence with the list interpolated, so a translator can reorder it.
                // The extension names are data reported by the browser and stay as they are.
                return report.enabledManagers.isEmpty
                    ? String(localized: "No recognized competing extensions were enabled at the last check.", comment: "Browser settings: competing password manager check status")
                    : String(localized: "Enabled managers: \(report.enabledManagers.joined(separator: ", ")). Disable them in this browser profile.", comment: "Browser settings: competing password manager check status; the argument is a comma-separated list of extension names")
            }
        }
    }
}

/// Transient by design: an app restart means no current observation, rather than an
/// old persisted green status. Pairing credentials are never retained in this store.
final class BrowserDiagnosticsStore: ObservableObject {
    static let shared = BrowserDiagnosticsStore()
    @Published private(set) var snapshots: [UUID: BrowserDiagnosticsSnapshot] = [:]

    func record(_ report: BrowserDiagnosticsReport, for browserID: UUID, receivedAt: Date) {
        snapshots[browserID] = BrowserDiagnosticsSnapshot(report: report, receivedAt: receivedAt)
    }

    func remove(browserID: UUID) {
        snapshots.removeValue(forKey: browserID)
    }
}
