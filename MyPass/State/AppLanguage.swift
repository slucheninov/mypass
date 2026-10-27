import Foundation

/// The user's interface-language choice: follow macOS, or force English, Ukrainian or Russian.
///
/// A language change cannot be applied live: SwiftUI resolves `LocalizedStringKey`s and
/// `String(localized:)` against the process's bundle language chosen at launch, so the choice
/// takes effect on the next launch (see `LanguageRestartController`).
enum AppLanguage: CaseIterable, Identifiable {
    case system
    case english
    case ukrainian
    case russian

    var id: String { code ?? "system" }

    /// The language code written into `AppleLanguages`; `nil` means "no override".
    var code: String? {
        switch self {
        case .system: return nil
        case .english: return "en"
        case .ukrainian: return "uk"
        case .russian: return "ru"
        }
    }

    /// Each language is shown in its own name so a user who ended up in a language they cannot
    /// read can still find theirs. Deliberately a plain `String`, never localized (the picker
    /// renders it with `Text(verbatim:)`, so it never enters the string catalog). `nil` for
    /// `.system`, whose label ("Use System Default") is translated.
    var nativeName: String? {
        switch self {
        case .system: return nil
        case .english: return "English"
        case .ukrainian: return "Українська"
        case .russian: return "Русский"
        }
    }
}

/// Reads and writes the per-app language override.
///
/// The override is the `AppleLanguages` key in the app's OWN defaults domain, which is exactly
/// what AppKit consults at launch before falling back to the global/system preference. It is
/// read from `persistentDomain(forName:)` and not from `defaults.array(forKey:)`, because the
/// latter also returns the global (system) value and would make "no override" impossible to
/// tell apart from "an override equal to the system language".
struct AppLanguageStore {
    static let storageKey = "AppleLanguages"

    private let defaults: UserDefaults
    private let domainName: String

    init(defaults: UserDefaults = .standard, domainName: String = Bundle.main.bundleIdentifier ?? "com.mypass.app") {
        self.defaults = defaults
        self.domainName = domainName
    }

    /// The first stored language's prefix decides (`"uk-UA"` is Ukrainian). An empty or
    /// unrecognised array (`["de"]`, written by hand or by another tool) reads as `.system` and
    /// is left untouched until the user picks something.
    var storedOverride: AppLanguage {
        guard let stored = defaults.persistentDomain(forName: domainName)?[Self.storageKey] as? [String],
              let first = stored.first else { return .system }
        let prefix = first.split(separator: "-").first.map(String.init) ?? first
        return AppLanguage.allCases.first { $0.code == prefix } ?? .system
    }

    func select(_ language: AppLanguage) {
        if let code = language.code {
            defaults.set([code], forKey: Self.storageKey)
        } else {
            defaults.removeObject(forKey: Self.storageKey)
        }
    }

    static func isRestartPending(launch: AppLanguage, current: AppLanguage) -> Bool {
        launch != current
    }

    /// The override this process was started with. A `static let` is initialised once, on first
    /// access, so `MyPassApp.init` touching it before anything can call `select` freezes the
    /// launch value; later choices then compare against it to decide whether a restart is due.
    static let launchSelection: AppLanguage = AppLanguageStore().storedOverride
}
