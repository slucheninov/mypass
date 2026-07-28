import Foundation

enum UnlockDeviceWindow: String, CaseIterable, Identifiable {
    case oneHour, fourHours, eightHours, twentyFourHours, never

    var id: String { rawValue }

    var pickerLabel: String {
        switch self {
        case .oneHour: return "For 1 hour"
        case .fourHours: return "For 4 hours"
        case .eightHours: return "For 8 hours"
        case .twentyFourHours: return "For 24 hours"
        case .never: return "Never"
        }
    }

    /// Window length in seconds, or `nil` for "never expires".
    var seconds: TimeInterval? {
        switch self {
        case .oneHour: return 3600
        case .fourHours: return 4 * 3600
        case .eightHours: return 8 * 3600
        case .twentyFourHours: return 24 * 3600
        case .never: return nil
        }
    }
}

enum RequirePasswordWindow: String, CaseIterable, Identifiable {
    case oneDay, sevenDays, fourteenDays, thirtyDays, ninetyDays, never

    var id: String { rawValue }

    var pickerLabel: String {
        switch self {
        case .oneDay: return "After 1 day"
        case .sevenDays: return "After 7 days"
        case .fourteenDays: return "After 14 days"
        case .thirtyDays: return "After 30 days"
        case .ninetyDays: return "After 90 days"
        case .never: return "Never"
        }
    }

    /// Window length in seconds, or `nil` for "never expires".
    var seconds: TimeInterval? {
        switch self {
        case .oneDay: return 86400
        case .sevenDays: return 7 * 86400
        case .fourteenDays: return 14 * 86400
        case .thirtyDays: return 30 * 86400
        case .ninetyDays: return 90 * 86400
        case .never: return nil
        }
    }
}

enum UnlockWindowPolicy {
    /// Whether device-based unlock (Touch ID / Mac password) may be offered right now,
    /// given when it and the real master password were each last used successfully.
    /// `nil` timestamps mean "never happened" and always return `false`, even if a
    /// window is `.never` (unlimited) — an unlimited window only excuses the passage
    /// of time since a *real* event, not the absence of one.
    static func deviceAuthAllowed(
        now: Date,
        lastDeviceUnlock: Date?,
        lastFullPasswordEntry: Date?,
        deviceWindow: UnlockDeviceWindow,
        accountPasswordWindow: RequirePasswordWindow
    ) -> Bool {
        guard let lastDeviceUnlock, let lastFullPasswordEntry else {
            return false
        }
        if let deviceSeconds = deviceWindow.seconds {
            guard now.timeIntervalSince(lastDeviceUnlock) <= deviceSeconds else { return false }
        }
        if let accountSeconds = accountPasswordWindow.seconds {
            guard now.timeIntervalSince(lastFullPasswordEntry) <= accountSeconds else { return false }
        }
        return true
    }
}
