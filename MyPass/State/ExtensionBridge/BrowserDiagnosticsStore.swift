import Combine
import Foundation
import ExtensionBridgeKit

struct BrowserDiagnosticsSnapshot: Equatable {
    let report: BrowserDiagnosticsReport
    let receivedAt: Date

    var passkeyStatus: String {
        switch report.proxyState {
        case .active: return "MyPass was ready to receive passkey requests at the last check."
        case .disabled: return "MyPass passkeys were turned off at the last check."
        case .locked: return "Unlock MyPass, then reopen its browser extension."
        case .unpaired: return "Connect this browser to MyPass again."
        case .unavailable: return "Open MyPass and reopen its browser extension to check passkeys."
        case .attachmentError: return "MyPass could not handle passkeys. Disable other passkey extensions, then check again."
        }
    }

    var passwordSavingStatus: String {
        switch report.passwordSavingEnabled {
        case true: return "Browser password saving: on"
        case false: return "Browser password saving: off"
        case nil: return "Browser password saving: unknown"
        }
    }

    var managerStatus: String {
        switch report.permissionState {
        case .notGranted: return "Check not allowed yet. In the MyPass extension, choose Check this browser and allow the check."
        case .unavailable: return "Browser check permission could not be read. Reopen the extension and try again."
        case .granted:
            switch report.extensionScanState {
            case .notChecked: return "Extension check has not run. Choose Check this browser in the MyPass extension."
            case .unavailable: return "Installed extensions could not be checked. Check them manually in your browser."
            case .complete:
                return report.enabledManagers.isEmpty
                    ? "No recognized competing extensions were enabled at the last check."
                    : "Enabled managers: " + report.enabledManagers.joined(separator: ", ") + ". Disable them in this browser profile."
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
