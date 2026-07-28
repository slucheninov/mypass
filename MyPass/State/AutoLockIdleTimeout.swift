import Foundation

enum AutoLockIdleTimeout: String, CaseIterable, Identifiable {
    case immediately, oneMinute, fiveMinutes, fifteenMinutes, thirtyMinutes, oneHour, fourHours, never

    var id: String { rawValue }

    var pickerLabel: String {
        switch self {
        case .immediately: return "Immediately"
        case .oneMinute: return "1 minute"
        case .fiveMinutes: return "5 minutes"
        case .fifteenMinutes: return "15 minutes"
        case .thirtyMinutes: return "30 minutes"
        case .oneHour: return "1 hour"
        case .fourHours: return "4 hours"
        case .never: return "Never"
        }
    }

    /// Idle duration in seconds before auto-lock fires, or `nil` for "never lock".
    var seconds: TimeInterval? {
        switch self {
        case .immediately: return 0
        case .oneMinute: return 60
        case .fiveMinutes: return 5 * 60
        case .fifteenMinutes: return 15 * 60
        case .thirtyMinutes: return 30 * 60
        case .oneHour: return 3600
        case .fourHours: return 4 * 3600
        case .never: return nil
        }
    }
}
