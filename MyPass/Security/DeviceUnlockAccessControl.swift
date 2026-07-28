import LocalAuthentication

enum DeviceUnlockAccessControl: Equatable {
    case touchID
    case devicePassword
    case touchIDOrDevicePassword

    var laPolicy: LAPolicy {
        switch self {
        case .touchID: return .deviceOwnerAuthenticationWithBiometrics
        case .devicePassword: return .deviceOwnerAuthentication
        case .touchIDOrDevicePassword: return .deviceOwnerAuthentication
        }
    }

    static func forToggles(touchIDEnabled: Bool, macPasswordEnabled: Bool) -> DeviceUnlockAccessControl? {
        switch (touchIDEnabled, macPasswordEnabled) {
        case (true, true): return .touchIDOrDevicePassword
        case (true, false): return .touchID
        case (false, true): return .devicePassword
        case (false, false): return nil
        }
    }
}
