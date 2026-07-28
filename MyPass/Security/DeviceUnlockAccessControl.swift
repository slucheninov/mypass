import Security

enum DeviceUnlockAccessControl: Equatable {
    case touchID
    case devicePassword
    case touchIDOrDevicePassword

    var secAccessControlFlags: SecAccessControlCreateFlags {
        switch self {
        case .touchID: return .biometryCurrentSet
        case .devicePassword: return .devicePasscode
        case .touchIDOrDevicePassword: return .userPresence
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
