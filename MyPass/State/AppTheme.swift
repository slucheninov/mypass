import AppKit

/// The user's appearance choice for the whole app: follow macOS, or force Light or Dark.
///
/// One mechanism only: `NSApplication.appearance`. Setting it on the application
/// covers every window, the `MenuBarExtra` panel, sheets and alerts in one place,
/// whereas SwiftUI's `preferredColorScheme` only reaches the view hierarchy it is
/// attached to and would leave the menu bar panel and AppKit alerts behind. For that
/// reason `preferredColorScheme` is not used anywhere in the app.
///
/// The raw values are the persisted names (`appTheme` in the app's defaults) and must
/// not change once shipped.
enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    /// `UserDefaults` / `@AppStorage` key holding the raw value.
    static let storageKey = "appTheme"

    var id: String { rawValue }

    /// Anything unrecognised (a hand-edited plist, a value written by a future
    /// version) falls back to following the system rather than failing.
    init(storedRaw: String?) {
        self = storedRaw.flatMap(AppTheme.init(rawValue:)) ?? .system
    }

    /// Menu title shown in the picker. A `LocalizedStringResource` so the computed title
    /// passes through the string catalog instead of being shown verbatim.
    var title: LocalizedStringResource {
        switch self {
        case .system: return "Match System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// `nil` means "no override": AppKit then follows the system appearance live.
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    @MainActor
    static func apply(_ theme: AppTheme, to app: NSApplication = .shared) {
        app.appearance = theme.appearance
    }
}
