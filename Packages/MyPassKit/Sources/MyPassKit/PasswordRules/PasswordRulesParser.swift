import Foundation

/// Parses Apple's Password Rules grammar
/// (https://developer.apple.com/password-rules/), the same grammar used by
/// the vendored `password-rules.json` (see
/// `Resources/PASSWORD_RULES_PROVENANCE.md`).
///
/// This parser deliberately does NOT match the leniency of Apple's own
/// reference implementation (`tools/PasswordRulesParser/PasswordRulesParser.js`
/// in `apple/password-manager-resources`), which logs a console warning and
/// silently degrades a malformed rule to "allow ascii-printable" rather than
/// failing outright. That leniency is the right default for a browser
/// autofill heuristic running against untrusted page content; it is the
/// wrong default for a password manager's own generator, where a malformed
/// rule silently producing a password the target site's real policy would
/// reject is a worse outcome than a typed, caller-visible parse error.
/// `PasswordRulesCatalog.rules(forHost:)` (Task 3) is what actually applies
/// leniency at the right boundary instead: a parse failure for one catalog
/// entry is treated as "this domain has no rule" (falls back to plain
/// generator toggles), not as a crash and not as a silently-wrong password.
public enum PasswordRulesParser {
    private static let namedClasses: [String: PasswordRules.CharacterClass] = [
        "upper": .upper,
        "lower": .lower,
        "digit": .digit,
        "special": .special,
        "ascii-printable": .asciiPrintable,
        "unicode": .unicode,
    ]

    public static func parse(_ raw: String) -> Result<PasswordRules, PasswordRulesParseError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.emptyInput) }

        let chars = Array(trimmed)
        var index = 0

        var requiredClauses: [[PasswordRules.CharacterClass]] = []
        var explicitAllowed: [PasswordRules.CharacterClass] = []
        var sawAllowedProperty = false
        var minLengths: [Int] = []
        var maxLengths: [Int] = []
        var maxConsecutives: [Int] = []
        var maxRepeatings: [Int] = []
        var maxSequentials: [Int] = []

        func skipWhitespace() {
            while index < chars.count, chars[index].isWhitespace {
                index += 1
            }
        }

        skipWhitespace()
        while index < chars.count {
            // Tolerate stray/repeated ';' between properties (real data
            // never has this, but Apple's own reference parser does not
            // error on it either -- see `_parsePasswordRulesInternal`).
            if chars[index] == ";" {
                index += 1
                skipWhitespace()
                continue
            }

            // Property names never contain ':', so the next ':' from here
            // is always THIS property's value-start sentinel -- safe to
            // search for directly rather than tokenizing character classes
            // (identifier characters only), because we are always
            // positioned at the start of a name when this runs.
            guard let colonIndex = chars[index...].firstIndex(of: ":") else {
                let remainder = String(chars[index...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return .failure(.unknownProperty(remainder))
            }
            let name = String(chars[index..<colonIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            index = colonIndex + 1
            skipWhitespace()

            switch name {
            case "required":
                switch parseClassListValue(chars, index: &index, property: name) {
                case .success(let classes): requiredClauses.append(classes)
                case .failure(let error): return .failure(error)
                }
            case "allowed":
                sawAllowedProperty = true
                switch parseClassListValue(chars, index: &index, property: name) {
                case .success(let classes):
                    for characterClass in classes where !explicitAllowed.contains(characterClass) {
                        explicitAllowed.append(characterClass)
                    }
                case .failure(let error): return .failure(error)
                }
            case "minlength":
                switch parseNonNegativeIntValue(chars, index: &index, property: name) {
                case .success(let n): minLengths.append(n)
                case .failure(let error): return .failure(error)
                }
            case "maxlength":
                switch parseNonNegativeIntValue(chars, index: &index, property: name) {
                case .success(let n): maxLengths.append(n)
                case .failure(let error): return .failure(error)
                }
            case "max-consecutive":
                switch parseNonNegativeIntValue(chars, index: &index, property: name) {
                case .success(let n): maxConsecutives.append(n)
                case .failure(let error): return .failure(error)
                }
            case "max-repeating":
                switch parseNonNegativeIntValue(chars, index: &index, property: name) {
                case .success(let n): maxRepeatings.append(n)
                case .failure(let error): return .failure(error)
                }
            case "max-sequential":
                switch parseNonNegativeIntValue(chars, index: &index, property: name) {
                case .success(let n): maxSequentials.append(n)
                case .failure(let error): return .failure(error)
                }
            default:
                return .failure(.unknownProperty(name))
            }

            skipWhitespace()
            if index < chars.count {
                guard chars[index] == ";" else {
                    return .failure(.malformedValue(property: name, value: String(chars[index...])))
                }
                index += 1
                skipWhitespace()
            }
        }

        // Every class named anywhere in requiredClauses is, definitionally,
        // also allowed -- folded in regardless of whether an explicit
        // `allowed:` property named it too. If no `allowed:` property was
        // ever seen, the base set defaults to ascii-printable.
        var allowedClasses = sawAllowedProperty ? explicitAllowed : [.asciiPrintable]
        for clause in requiredClauses {
            for characterClass in clause where !allowedClasses.contains(characterClass) {
                allowedClasses.append(characterClass)
            }
        }

        return .success(PasswordRules(
            requiredClauses: requiredClauses,
            allowedClasses: allowedClasses,
            minLength: minLengths.max(),
            maxLength: maxLengths.min(),
            maxConsecutive: maxConsecutives.min(),
            maxRepeating: maxRepeatings.min(),
            maxSequential: maxSequentials.min()
        ))
    }

    /// Parses one `required:`/`allowed:` value: comma-separated tokens,
    /// each a named identifier or a bracketed custom class, stopping at the
    /// first top-level ';' (never inside a bracket) or end of input.
    /// Matches Apple's reference `_parsePasswordRequiredOrAllowedPropertyValue`.
    private static func parseClassListValue(
        _ chars: [Character],
        index: inout Int,
        property: String
    ) -> Result<[PasswordRules.CharacterClass], PasswordRulesParseError> {
        var classes: [PasswordRules.CharacterClass] = []

        func skipHorizontalWhitespace() {
            while index < chars.count, chars[index] == " " || chars[index] == "\t" {
                index += 1
            }
        }

        skipHorizontalWhitespace()
        while index < chars.count, chars[index] != ";" {
            if chars[index] == "[" {
                switch parseCustomCharacterClass(chars, from: &index) {
                case .success(let members):
                    // An empty custom class ("[]") contributes nothing,
                    // matching the reference parser's "[], [b]" -> ["[b]"].
                    if !members.isEmpty {
                        classes.append(.custom(Set(members)))
                    }
                case .failure(let error):
                    return .failure(error)
                }
            } else {
                var token = ""
                while index < chars.count, chars[index] != ",", chars[index] != ";" {
                    token.append(chars[index])
                    index += 1
                }
                let identifier = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard let characterClass = namedClasses[identifier] else {
                    return .failure(.malformedValue(property: property, value: identifier))
                }
                classes.append(characterClass)
            }

            skipHorizontalWhitespace()
            guard index < chars.count else { break }
            if chars[index] == "," {
                index += 1
                skipHorizontalWhitespace()
            } else if chars[index] == ";" {
                break
            } else {
                return .failure(.malformedValue(property: property, value: String(chars[index...])))
            }
        }

        guard !classes.isEmpty else {
            return .failure(.malformedValue(property: property, value: ""))
        }
        return .success(classes)
    }

    /// Scans one bracketed custom class starting at `chars[index] == "["`,
    /// advancing `index` past its closing bracket. Matches Apple's
    /// reference `_parseCustomCharacterClass` exactly, including its two
    /// least-obvious rules:
    ///
    /// 1. A `]` is tentatively treated as the closing delimiter, but if the
    ///    very next character is ALSO `]`, the first one was a literal
    ///    member instead and the second one closes the class -- this is
    ///    how `costco.com`'s real rule, ending
    ///    `required: [-!#$%&'()*+/:;=?@[^_\`{|}~]];`, encodes a class that
    ///    contains both a literal `[` and a literal `]`.
    /// 2. A `-` is a literal member only when it is the very first
    ///    character after `[`; anywhere else it is silently dropped
    ///    (non-fatal, matching the reference parser's own "a '-' may only
    ///    appear as the first character" behavior).
    ///
    /// Any other ASCII-printable character (0x20...0x7E), `;` and `,`
    /// included, is an ordinary literal member; non-ASCII-printable
    /// characters are silently skipped.
    private static func parseCustomCharacterClass(
        _ chars: [Character],
        from index: inout Int
    ) -> Result<[Character], PasswordRulesParseError> {
        precondition(chars[index] == "[")
        index += 1
        let start = index
        var members: [Character] = []

        while index < chars.count {
            let c = chars[index]
            guard let ascii = c.asciiValue, ascii >= 0x20, ascii <= 0x7E else {
                index += 1
                continue
            }
            if c == "-", index > start {
                index += 1
                continue
            }
            members.append(c)
            index += 1
            if c == "]" {
                break
            }
        }

        guard let last = members.last, last == "]" else {
            return .failure(.unterminatedCustomClass)
        }

        if index < chars.count, chars[index] == "]" {
            // Doubled "]]": the first was a literal member (already
            // appended above), the second is the real closing delimiter.
            index += 1
            return .success(members)
        }

        // The single "]" we appended was the delimiter, not a member.
        members.removeLast()
        return .success(members)
    }

    private static func parseNonNegativeIntValue(
        _ chars: [Character],
        index: inout Int,
        property: String
    ) -> Result<Int, PasswordRulesParseError> {
        var digits = ""
        while index < chars.count, chars[index] != ";" {
            digits.append(chars[index])
            index += 1
        }
        let trimmed = digits.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let n = Int(trimmed), n >= 0 else {
            return .failure(.malformedValue(property: property, value: trimmed))
        }
        return .success(n)
    }
}
