import Foundation
import MyPassKit

/// Persisted defaults for the password generator, in the `MyPass.`-prefixed
/// key namespace this codebase already uses for its custom vault fields
/// (`MyPass.CVV`, `MyPass.NotesBody`, etc. in `KdbxEntry+Convenience.swift`)
/// -- these keys live in `UserDefaults`, not the vault, but the naming
/// convention is shared deliberately so every MyPass-owned persisted key in
/// this codebase is recognizable at a glance.
///
/// `UserDefaults` is injectable specifically so tests use a throwaway suite
/// (see `PasswordGeneratorDefaultsTests.swift`) rather than polluting the
/// developer's real defaults -- the same pattern already established by
/// `ClipboardClearInterval.seconds(defaults:)`.
enum PasswordGeneratorDefaults {
    static let lengthKey = "MyPass.PasswordGenerator.length"
    static let includeLowercaseKey = "MyPass.PasswordGenerator.includeLowercase"
    static let includeUppercaseKey = "MyPass.PasswordGenerator.includeUppercase"
    static let includeDigitsKey = "MyPass.PasswordGenerator.includeDigits"
    static let includeSymbolsKey = "MyPass.PasswordGenerator.includeSymbols"

    // Matches PasswordGeneratorView's own pre-persistence hard-coded
    // defaults (length 16 was the OLD default before this task; the spec's
    // Decision 6 sets the new documented default to 20, so both the
    // fallback here and the view's initial state after Task 7 must read
    // 20, not 16).
    private static let defaultLength = 20
    private static let defaultIncludeClass = true

    static func load(from defaults: UserDefaults = .standard) -> PasswordGeneratorOptions {
        // `.integer(forKey:)`/`.bool(forKey:)` return 0/false when the key
        // is absent, which is indistinguishable from "the user explicitly
        // chose 0 characters" or "explicitly turned this class off" --
        // `.object(forKey:) as? T` correctly returns nil when absent, so
        // the `??` fallback below only fires on a genuinely-unset default.
        let length = defaults.object(forKey: lengthKey) as? Int ?? defaultLength
        let includeLowercase = defaults.object(forKey: includeLowercaseKey) as? Bool ?? defaultIncludeClass
        let includeUppercase = defaults.object(forKey: includeUppercaseKey) as? Bool ?? defaultIncludeClass
        let includeDigits = defaults.object(forKey: includeDigitsKey) as? Bool ?? defaultIncludeClass
        let includeSymbols = defaults.object(forKey: includeSymbolsKey) as? Bool ?? defaultIncludeClass
        return PasswordGeneratorOptions(
            length: length,
            includeLowercase: includeLowercase,
            includeUppercase: includeUppercase,
            includeDigits: includeDigits,
            includeSymbols: includeSymbols
        )
    }

    static func save(_ options: PasswordGeneratorOptions, to defaults: UserDefaults = .standard) {
        defaults.set(options.length, forKey: lengthKey)
        defaults.set(options.includeLowercase, forKey: includeLowercaseKey)
        defaults.set(options.includeUppercase, forKey: includeUppercaseKey)
        defaults.set(options.includeDigits, forKey: includeDigitsKey)
        defaults.set(options.includeSymbols, forKey: includeSymbolsKey)
    }
}
