import Foundation

/// A bounded observation from one paired browser profile, never proof that all other
/// providers are disabled. The app supplies identity and receipt time independently.
public struct BrowserDiagnosticsReport: Codable, Equatable {
    public enum ProxyState: String, Codable {
        case active, disabled, locked, unpaired, unavailable
        case attachmentError = "attachment-error"
    }

    public enum PermissionState: String, Codable {
        case granted, unavailable
        case notGranted = "not-granted"
    }

    public enum ExtensionScanState: String, Codable {
        case complete, unavailable
        case notChecked = "not-checked"
    }

    public let proxyState: ProxyState
    public let permissionState: PermissionState
    public let passwordSavingEnabled: Bool?
    public let extensionScanState: ExtensionScanState
    public let enabledManagers: [String]

    public init(proxyState: ProxyState, permissionState: PermissionState, passwordSavingEnabled: Bool?,
                extensionScanState: ExtensionScanState, enabledManagers: [String]) {
        self.proxyState = proxyState
        self.permissionState = permissionState
        self.passwordSavingEnabled = passwordSavingEnabled
        self.extensionScanState = extensionScanState
        self.enabledManagers = enabledManagers
    }

    public var isValid: Bool {
        guard enabledManagers.count <= 20,
              enabledManagers.allSatisfy({ name in
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && name.count <= 120
                      && !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
              }) else { return false }
        guard extensionScanState == .complete || enabledManagers.isEmpty else { return false }
        return permissionState == .granted || (passwordSavingEnabled == nil && extensionScanState == .notChecked)
    }
}
