import MyPassKit

/// Turns a parsed `PasswordRules` into a short, plain-English sentence for
/// the generator popover (Decision 5 of the spec) -- never the raw grammar
/// string ("minlength: 8; required: digit;"), which is meant for machines,
/// not for a person deciding whether to trust the password MyPass just
/// generated for them.
enum PasswordRulesSummary {
    /// Toggle-backed classes this summary reasons about, and their display
    /// order wherever it renders a list of them -- matches
    /// `PasswordRulesToggleEvaluator`'s own order so the popover text and
    /// the toggle UI it sits next to never disagree about ordering either.
    private static let toggleBackedClassOrder: [PasswordRules.CharacterClass] = [.lower, .upper, .digit, .special]

    static func describe(_ rules: PasswordRules, domain: String) -> String {
        var fragments: [String] = []

        for orClause in rules.requiredClauses {
            fragments.append(orClause.map(name(for:)).joined(separator: " or "))
        }

        if let permitted = permittedFragment(for: rules) {
            fragments.append(permitted)
        }

        if let minLength = rules.minLength, let maxLength = rules.maxLength {
            fragments.append(
                minLength == maxLength
                    ? "exactly \(minLength) characters"
                    : "\(minLength) to \(maxLength) characters"
            )
        } else if let minLength = rules.minLength {
            fragments.append("at least \(minLength) characters")
        } else if let maxLength = rules.maxLength {
            fragments.append("at most \(maxLength) characters")
        }

        if let maxConsecutive = rules.maxConsecutive {
            fragments.append("at most \(maxConsecutive) repeated characters in a row")
        }

        guard !fragments.isEmpty else {
            return "\(domain) has no specific password requirements."
        }
        return "\(domain) needs " + fragments.joined(separator: ", ") + "."
    }

    /// Names the rule's permitted toggle-backed classes whenever
    /// `allowed:` restricts them beyond what `required:` alone already
    /// conveys -- nil when the rule has no explicit `allowed:` restriction
    /// at all, or when the restriction still leaves all four toggle-backed
    /// classes open (not a real restriction from the toggle UI's point of
    /// view). Delegates the actual "what does `allowed:` restrict"
    /// question to `PasswordRulesToggleEvaluator`, the same logic
    /// `PasswordGeneratorView` uses to decide which toggles to lock, so
    /// this sentence and that UI can never disagree about which classes a
    /// rule permits.
    ///
    /// Without this, a rule like amundi-ee.com's ("minlength: 6;
    /// maxlength: 6; allowed: digit; max-consecutive: 3" -- a six-digit
    /// PIN) rendered a sentence about length and repeated characters and
    /// said nothing about digits being the only permitted character, even
    /// though `PasswordGeneratorView` visibly locks every other toggle off
    /// for that same rule -- the plain-English summary and the toggle UI
    /// it sits next to told two different stories about the site's
    /// policy. Deliberately scoped to the same four toggle-backed classes
    /// `PasswordRulesToggleEvaluator` reasons about: a bespoke custom
    /// `allowed:` class (e.g. aetna.com's `[-_&#@]`) is not folded into
    /// this list, for the same reason `name(for:)` never spells out a
    /// custom class's literal members -- see that function's doc comment.
    private static func permittedFragment(for rules: PasswordRules) -> String? {
        guard let permitted = PasswordRulesToggleEvaluator.restrictedAllowedToggleClasses(for: rules),
              !permitted.isEmpty, permitted.count < toggleBackedClassOrder.count
        else {
            return nil
        }
        let names = toggleBackedClassOrder.filter(permitted.contains).map(pluralName(for:))
        return "only " + names.joined(separator: ", ") + " are permitted"
    }

    private static func name(for characterClass: PasswordRules.CharacterClass) -> String {
        switch characterClass {
        case .upper: return "an uppercase letter"
        case .lower: return "a lowercase letter"
        case .digit: return "a digit"
        case .special: return "a symbol"
        case .asciiPrintable: return "a printable character"
        case .unicode: return "a unicode character"
        case .custom(let members): return "a required " + customClassNoun(for: members)
        }
    }

    /// Apple's Password Rules grammar lets a bracketed custom class list
    /// ANY characters, not just punctuation -- `[ABC]` is a valid (if
    /// unusual) custom class naming three uppercase letters. Calling every
    /// custom class "a required symbol" regardless of its actual members
    /// is simply wrong when those members are letters or digits, so this
    /// classifies by what the class's members actually contain instead of
    /// assuming "custom" always means "symbol." Printing the literal
    /// member characters themselves is deliberately still avoided --
    /// unreadable for a class naming dozens of characters, and more detail
    /// than a one-sentence summary needs -- so this only ever names the
    /// general kind of character the class contains, falling back to
    /// "symbol" for anything that isn't uniformly letters or digits
    /// (Apple's custom classes are most commonly used for a bespoke
    /// punctuation set standard `special` doesn't cover, so that fallback
    /// is the right default for a mixed or punctuation-only class).
    private static func customClassNoun(for members: Set<Character>) -> String {
        guard !members.isEmpty else { return "symbol" }
        if members.allSatisfy({ $0.isLetter }) { return "letter" }
        if members.allSatisfy({ $0.isNumber }) { return "digit" }
        return "symbol"
    }

    /// Plural, article-free class names for a list context ("only digits
    /// and symbols are permitted"), as opposed to `name(for:)`'s singular,
    /// article-bearing form for a single required class ("a digit"). Kept
    /// as its own function, and `internal` (no access modifier) rather
    /// than `private`, so `PasswordGeneratorView`'s own conflict-warning
    /// text (see `PasswordRulesToggleEvaluator.Evaluation.conflictingWithAllowedClasses`)
    /// uses the identical wording this summary uses, rather than a second,
    /// independently-worded description of the same classes.
    static func pluralName(for characterClass: PasswordRules.CharacterClass) -> String {
        switch characterClass {
        case .upper: return "uppercase letters"
        case .lower: return "lowercase letters"
        case .digit: return "digits"
        case .special: return "symbols"
        case .asciiPrintable: return "printable characters"
        case .unicode: return "unicode characters"
        case .custom: return "custom characters"
        }
    }
}
