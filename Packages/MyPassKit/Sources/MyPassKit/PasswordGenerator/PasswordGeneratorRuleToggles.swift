import Foundation

/// How a `PasswordRules` value constrains the generator's four user-facing
/// character-class toggles (lowercase, uppercase, digits, symbols).
///
/// This is deliberately part of `PasswordGenerator` rather than of the app's
/// UI layer. Two independent answers to "what does this rule permit, given
/// these toggles?" already existed -- `effectivePool` below decided it for
/// generation, and `PasswordRulesToggleEvaluator` in `MyPass/UI/` decided it
/// again for toggle locking and for the popover's plain-English summary --
/// and a whole-branch review found the two disagreeing in both directions:
///
/// * The UI locked digits ON for a sole-allowed-class rule (amundi-ee.com's
///   `allowed: digit`), while `effectivePool` forced in only `required:`
///   classes. With digits toggled off, the app's own generator therefore
///   succeeded (its UI had already forced the toggle) while the extension
///   bridge -- which reads the persisted toggles directly, with no UI to
///   force anything -- threw `noCharacterClassSelected` and reported "no
///   character types are enabled," which was false when three of the four
///   were on.
/// * `effectivePool` added an `allowed:` custom class's literal characters
///   unconditionally, while the UI's locked-off computation and the summary
///   reasoned only about the four toggle-backed classes. classmates.com's
///   `allowed: lower, upper, digit, [!@#$%^&*]` therefore locked Symbols off
///   and told the user only letters and digits were permitted, while the
///   generated password could contain those eight symbols.
///
/// Everything below is the single answer both surfaces now read. The UI layer
/// presents it; it no longer re-derives it.
extension PasswordGenerator {
    /// The four classes the generator exposes as toggles, in the display
    /// order any caller rendering a list of them should use. `.asciiPrintable`,
    /// `.unicode` and `.custom` are deliberately absent: none of them has a
    /// toggle of its own, and each is folded into this vocabulary by
    /// `permittedToggleClasses(for:)` below.
    public static let toggleBackedClasses: [PasswordRules.CharacterClass] = [.lower, .upper, .digit, .special]

    /// Which toggle-backed class a single literal character belongs to --
    /// the bridge between Apple's bracketed custom classes, whose members
    /// are arbitrary characters, and this generator's four toggles.
    ///
    /// Anything that is not an ASCII digit or ASCII letter is classified as
    /// `.special`, including a non-ASCII letter: dkb.de's real rule allows
    /// `[-äüöÄÜÖß!$%&/()=?+#,.:]`, and while MyPass never *emits* a non-ASCII
    /// character (see `effectivePool`'s note on `.unicode`), a rule that
    /// names one is still telling us it permits characters outside the
    /// letters-and-digits set -- which is the question this function exists
    /// to answer. Classifying such a member as `.special` errs toward "the
    /// site permits more than letters and digits," which is true, rather
    /// than toward locking a toggle off on a rule that never asked for it.
    public static func toggleBackedClass(of character: Character) -> PasswordRules.CharacterClass {
        if character.isASCII {
            if character.isNumber { return .digit }
            if character.isUppercase { return .upper }
            if character.isLowercase { return .lower }
        }
        return .special
    }

    /// The toggle-backed classes this rule permits at all -- nil when the
    /// rule places no restriction on the character set, in which case the
    /// user's own toggles alone decide.
    ///
    /// Two cases both mean "no restriction," mirroring `effectivePool`'s own
    /// `noExplicitAllowList` / `asciiPrintableInPlay` handling: an EMPTY
    /// `allowedClasses` (no explicit `allowed:` property was present when the
    /// rule was parsed), and a set that explicitly names `.asciiPrintable`
    /// (Apple's grammar for "any of these four is fine"). `PasswordRulesParser`
    /// never actually produces the empty case today -- a rule with no
    /// `allowed:` property defaults to `[.asciiPrintable]` -- but relying on
    /// that as an unstated invariant, rather than checking for it explicitly,
    /// is exactly the kind of latent divergence this type exists to remove.
    ///
    /// A custom class in `allowed:` contributes the toggle-backed classes of
    /// its own members (see `toggleBackedClass(of:)`). Without that,
    /// classmates.com's `allowed: lower, upper, digit, [!@#$%^&*]` reported
    /// `.special` as excluded, which the generated password then contradicted.
    /// `PasswordRulesParser` folds every `required:` class into
    /// `allowedClasses`, so a required custom class is covered here too --
    /// acmemarkets.com (`required: [!#$%&*@^]; allowed: lower,digit;`) used
    /// to claim symbols were forbidden while every password it generated
    /// contained one by construction.
    ///
    /// Note this is a question about the RULE only, never about the
    /// generator's own character pools: `.special` appearing here means "the
    /// rule permits at least one character that is not an ASCII letter or
    /// digit," not "MyPass's whole symbol pool is in play." `effectivePool`
    /// keeps those separate -- it adds a baseline pool only for a class the
    /// rule names directly.
    public static func permittedToggleClasses(for rules: PasswordRules) -> Set<PasswordRules.CharacterClass>? {
        guard !rules.allowedClasses.isEmpty, !rules.allowedClasses.contains(.asciiPrintable) else {
            return nil
        }
        var permitted = Set(toggleBackedClasses).intersection(rules.allowedClasses)
        for characterClass in rules.allowedClasses {
            guard case .custom(let members) = characterClass else { continue }
            for member in members {
                permitted.insert(toggleBackedClass(of: member))
            }
        }
        return permitted
    }

    /// Toggle-backed classes the generator includes regardless of the user's
    /// own toggle: the rule's `required:` clauses (Decision 4 of the spec --
    /// "a site that mandates a digit gets one even if the user turned digits
    /// off"), plus one further case `required:` alone does not cover.
    ///
    /// Some real vendored rules restrict the character set without requiring
    /// anything. amundi-ee.com's whole rule is "minlength: 6; maxlength: 6;
    /// allowed: digit; max-consecutive: 3" -- a six-digit PIN. There is no
    /// `required:` clause naming digits at all, but digits are the ONLY
    /// character this rule permits, so a user whose saved defaults have
    /// digits turned off would otherwise get an opaque
    /// `noCharacterClassSelected` failure for a rule that is perfectly
    /// satisfiable.
    ///
    /// Deliberately NOT extended to a permitted set of two or more classes:
    /// there the user has a genuine choice among the permitted classes, and
    /// forcing one of them on regardless of the user's own preference would
    /// take that choice away. The UI surfaces that broader case as a visible
    /// warning instead, without picking a class for the user.
    public static func forcedOnToggleClasses(for rules: PasswordRules) -> Set<PasswordRules.CharacterClass> {
        var forced = Set(rules.requiredClauses.flatMap { $0 }).intersection(Set(toggleBackedClasses))
        if let permitted = permittedToggleClasses(for: rules), permitted.count == 1 {
            forced.formUnion(permitted)
        }
        return forced
    }

    /// The toggle-backed classes the rule excludes entirely -- empty when the
    /// rule places no restriction on the character set at all.
    public static func excludedToggleClasses(for rules: PasswordRules) -> Set<PasswordRules.CharacterClass> {
        guard let permitted = permittedToggleClasses(for: rules) else { return [] }
        return Set(toggleBackedClasses).subtracting(permitted)
    }

    /// `options` with the rule's forcing applied: a forced-on class is turned
    /// on, an excluded class is turned off, and the length is clamped into
    /// the rule's own bounds. The user's stored preference is never mutated
    /// by this -- callers derive these options for one generation and keep
    /// persisting whatever the user actually chose.
    ///
    /// `generate(options:rules:)` applies the same forcing internally, so
    /// passing the result of this function back into it is idempotent rather
    /// than doubly-applied. It exists so the UI can show the user, before
    /// pressing Generate, exactly the configuration generation will use.
    public static func effectiveOptions(
        for options: PasswordGeneratorOptions,
        rules: PasswordRules
    ) -> PasswordGeneratorOptions {
        let forcedOn = forcedOnToggleClasses(for: rules)
        let excluded = excludedToggleClasses(for: rules)
        func resolve(_ characterClass: PasswordRules.CharacterClass, _ current: Bool) -> Bool {
            if forcedOn.contains(characterClass) { return true }
            if excluded.contains(characterClass) { return false }
            return current
        }
        var length = options.length
        if let ruleMin = rules.minLength { length = Swift.max(length, ruleMin) }
        if let ruleMax = rules.maxLength { length = Swift.min(length, ruleMax) }
        return PasswordGeneratorOptions(
            length: length,
            includeLowercase: resolve(.lower, options.includeLowercase),
            includeUppercase: resolve(.upper, options.includeUppercase),
            includeDigits: resolve(.digit, options.includeDigits),
            includeSymbols: resolve(.special, options.includeSymbols)
        )
    }
}
