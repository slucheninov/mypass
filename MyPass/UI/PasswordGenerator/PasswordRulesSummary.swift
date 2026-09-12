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

    /// Two sentences, not one list: `required:`, the length bounds and
    /// `max-consecutive` form a "needs" sentence, and what `allowed:`
    /// permits (when it restricts anything) is a separate sentence after
    /// it. An earlier version of this function appended the permitted-set
    /// wording as one more item in the same comma-joined "needs" list --
    /// but that fragment is a full clause with its own verb ("only digits
    /// are permitted"), not a noun phrase like the others ("a digit", "8
    /// to 15 characters"), so dropping it into that list produced
    /// "needs only digits are permitted" (not a sentence) and, worse,
    /// "needs an uppercase letter, a digit, only lowercase letters...",
    /// which reads as though "only lowercase letters" were one more
    /// required item -- the exact opposite of what it means. Keeping the
    /// permitted set in its own sentence, after the "needs" sentence is
    /// complete, removes that ambiguity entirely.
    static func describe(_ rules: PasswordRules, domain: String) -> String {
        var needsFragments: [String] = []

        for orClause in rules.requiredClauses {
            needsFragments.append(orClause.map(name(for:)).joined(separator: " or "))
        }

        if let minLength = rules.minLength, let maxLength = rules.maxLength {
            needsFragments.append(
                minLength == maxLength
                    ? "exactly \(minLength) characters"
                    : "\(minLength) to \(maxLength) characters"
            )
        } else if let minLength = rules.minLength {
            needsFragments.append("at least \(minLength) characters")
        } else if let maxLength = rules.maxLength {
            needsFragments.append("at most \(maxLength) characters")
        }

        if let maxConsecutive = rules.maxConsecutive {
            needsFragments.append("at most \(maxConsecutive) repeated characters in a row")
        }

        let permittedNames = permittedNamesJoined(for: rules)

        guard !needsFragments.isEmpty else {
            // A rule can say nothing beyond restricting the character set
            // (e.g. a bare "allowed: lower, upper;" with no length or
            // required properties at all) -- there is no "needs" content
            // to build a first sentence from, so this must not produce a
            // dangling "{domain} needs ." with nothing after it. Naming
            // the domain as the subject of "only allows" keeps this a
            // real, standalone sentence instead.
            if let permittedNames {
                return "\(domain) only allows \(permittedNames)."
            }
            return "\(domain) has no specific password requirements."
        }

        let needsSentence = "\(domain) needs " + joinedWithAnd(needsFragments) + "."
        guard let permittedNames else { return needsSentence }
        return needsSentence + " Only \(permittedNames) are permitted."
    }

    /// The rule's permitted toggle-backed classes, joined into one
    /// English list, whenever `allowed:` restricts them beyond what
    /// `required:` alone already conveys -- nil when the rule has no
    /// explicit `allowed:` restriction at all, or when the restriction
    /// still leaves all four toggle-backed classes open (not a real
    /// restriction from the toggle UI's point of view). Delegates the
    /// actual "what does `allowed:` restrict" question to
    /// `PasswordRulesToggleEvaluator`, the same logic `PasswordGeneratorView`
    /// uses to decide which toggles to lock, so this sentence and that UI
    /// can never disagree about which classes a rule permits.
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
    private static func permittedNamesJoined(for rules: PasswordRules) -> String? {
        guard let permitted = PasswordRulesToggleEvaluator.restrictedAllowedToggleClasses(for: rules),
              !permitted.isEmpty, permitted.count < toggleBackedClassOrder.count
        else {
            return nil
        }
        let names = toggleBackedClassOrder.filter(permitted.contains).map(pluralName(for:))
        return joinedWithAnd(names)
    }

    private static func name(for characterClass: PasswordRules.CharacterClass) -> String {
        switch characterClass {
        case .upper: return "an uppercase letter"
        case .lower: return "a lowercase letter"
        case .digit: return "a digit"
        case .special: return "a symbol"
        case .asciiPrintable: return "a printable character"
        case .unicode: return "a unicode character"
        case .custom(let members): return "a " + customClassNoun(for: members)
        }
    }

    /// Apple's Password Rules grammar lets a bracketed custom class list
    /// ANY characters, not just punctuation -- `[ABC]` is a valid (if
    /// unusual) custom class naming three uppercase letters. Calling every
    /// custom class "a symbol" regardless of its actual members is simply
    /// wrong when those members are letters or digits, so this classifies
    /// by what the class's members actually contain instead of assuming
    /// "custom" always means "symbol." Printing the literal member
    /// characters themselves is deliberately still avoided -- unreadable
    /// for a class naming dozens of characters, and more detail than a
    /// one-sentence summary needs -- so this only ever names the general
    /// kind of character the class contains, falling back to "symbol" for
    /// anything that isn't uniformly letters or digits (Apple's custom
    /// classes are most commonly used for a bespoke punctuation set
    /// standard `special` doesn't cover, so that fallback is the right
    /// default for a mixed or punctuation-only class).
    private static func customClassNoun(for members: Set<Character>) -> String {
        guard !members.isEmpty else { return "symbol" }
        if members.allSatisfy({ $0.isLetter }) { return "letter" }
        if members.allSatisfy({ $0.isNumber }) { return "digit" }
        return "symbol"
    }

    /// Plural, article-free class names for a list context ("digits and
    /// symbols"), as opposed to `name(for:)`'s singular, article-bearing
    /// form for a single required class ("a digit"). Kept as its own
    /// function, and `internal` (no access modifier) rather than
    /// `private`, so `PasswordGeneratorView`'s own conflict-warning text
    /// (see `PasswordRulesToggleEvaluator.Evaluation.conflictingWithAllowedClasses`)
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

    /// Joins a list of fragments as ordinary English -- "A", "A and B", or
    /// "A, B and C" -- rather than a bare comma before the final item.
    /// `internal` (no access modifier) rather than `private` so
    /// `PasswordGeneratorView`'s conflict-warning text (which lists the
    /// same kind of class names this summary does) reads the same way,
    /// rather than the two ending up with two different list styles for
    /// what is, to a reader, the identical kind of sentence.
    static func joinedWithAnd(_ items: [String]) -> String {
        guard let last = items.last else { return "" }
        guard items.count > 1 else { return last }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }
}
