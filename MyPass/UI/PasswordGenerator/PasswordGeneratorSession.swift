import Foundation
import MyPassKit

/// The one place a Generate press in `PasswordGeneratorView` turns into a
/// persisted preference plus a password, extracted from the view purely so it
/// is reachable from XCTest -- a SwiftUI `View`'s `@State` and its private
/// methods are not, and this exact decision shipped wrong once already.
///
/// The bug it exists to pin: the view used to overwrite its own toggle state
/// with the active site rule's locked-on/locked-off decisions, then build the
/// options it generated from AND persisted out of those mutated values. That
/// save site is the only writer of `PasswordGeneratorDefaults`, and both the
/// app's generator and the extension bridge's `generatePassword` handler read
/// it -- so generating once for a site whose rule restricts the character set
/// made that site's restriction the user's permanent global default. Using
/// the generator on amundi-ee.com (`allowed: digit`, a six-digit PIN) silently
/// narrowed every later password for every other site, including every one the
/// extension requests, to digits only, with no UI anywhere that revealed the
/// state.
///
/// The separation below is the fix and is not negotiable: `userOptions` is the
/// user's own stored preference and is the only thing persisted; the rule's
/// forcing is applied by `PasswordGenerator` for this one generation and is
/// never written back.
enum PasswordGeneratorSession {
    /// Persists exactly the user's own choice, then generates honouring
    /// `rule`. `defaults` is injectable for the same reason
    /// `PasswordGeneratorDefaults.load(from:)`'s is: tests use a throwaway
    /// suite rather than the developer's real defaults.
    static func generate(
        userOptions: PasswordGeneratorOptions,
        rule: PasswordRules?,
        defaults: UserDefaults = .standard
    ) throws -> String {
        PasswordGeneratorDefaults.save(userOptions, to: defaults)
        return try PasswordGenerator.generate(options: userOptions, rules: rule)
    }
}
