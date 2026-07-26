import Foundation

enum ClipboardClearInterval {
    static func seconds(defaults: UserDefaults = .standard) -> TimeInterval {
        let stored = defaults.object(forKey: "clipboardClearSeconds") as? Int
        return TimeInterval(stored ?? 30)
    }
}
