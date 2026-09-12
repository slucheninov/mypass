import MyPassKit

/// Turns a parsed `PasswordRules` into a short, plain-English sentence for
/// the generator popover (Decision 5 of the spec) -- never the raw grammar
/// string ("minlength: 8; required: digit;"), which is meant for machines,
/// not for a person deciding whether to trust the password MyPass just
/// generated for them.
enum PasswordRulesSummary {
    static func describe(_ rules: PasswordRules, domain: String) -> String {
        var fragments: [String] = []

        for orClause in rules.requiredClauses {
            fragments.append(orClause.map(name(for:)).joined(separator: " or "))
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

    private static func name(for characterClass: PasswordRules.CharacterClass) -> String {
        switch characterClass {
        case .upper: return "an uppercase letter"
        case .lower: return "a lowercase letter"
        case .digit: return "a digit"
        case .special: return "a symbol"
        case .asciiPrintable: return "a printable character"
        case .unicode: return "a unicode character"
        case .custom: return "a required symbol"
        }
    }
}
