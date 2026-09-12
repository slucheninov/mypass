import Foundation

/// Apple's Password Rules grammar (https://developer.apple.com/password-rules/),
/// parsed into a structured value. See `PasswordRulesParser.parse(_:)` for
/// the parser and `PasswordRulesCatalog.rules(forHost:)` for domain lookup.
public struct PasswordRules: Equatable {
    public enum CharacterClass: Equatable, Hashable {
        case upper
        case lower
        case digit
        case special
        case asciiPrintable
        case unicode
        case custom(Set<Character>)
    }

    /// Each inner array is one `required:` clause -- its members are ORed.
    /// The outer array is the AND of every `required:` clause present.
    public var requiredClauses: [[CharacterClass]]
    /// The cumulative `allowed:` set, with every class named by any
    /// `requiredClauses` member already folded in.
    public var allowedClasses: [CharacterClass]
    public var minLength: Int?
    public var maxLength: Int?
    public var maxConsecutive: Int?
    /// Parsed and stored, never enforced by `PasswordGenerator` -- see
    /// that type's doc comment on why (Task 4 of
    /// docs/superpowers/plans/2026-09-12-site-password-rules-and-uri-matching.md).
    public var maxRepeating: Int?
    /// Parsed and stored, never enforced by `PasswordGenerator` -- see
    /// that type's doc comment on why.
    public var maxSequential: Int?

    init(
        requiredClauses: [[CharacterClass]] = [],
        allowedClasses: [CharacterClass] = [],
        minLength: Int? = nil,
        maxLength: Int? = nil,
        maxConsecutive: Int? = nil,
        maxRepeating: Int? = nil,
        maxSequential: Int? = nil
    ) {
        self.requiredClauses = requiredClauses
        self.allowedClasses = allowedClasses
        self.minLength = minLength
        self.maxLength = maxLength
        self.maxConsecutive = maxConsecutive
        self.maxRepeating = maxRepeating
        self.maxSequential = maxSequential
    }
}

public enum PasswordRulesParseError: Error, Equatable {
    case emptyInput
    case unknownProperty(String)
    case malformedValue(property: String, value: String)
    case unterminatedCustomClass
}
