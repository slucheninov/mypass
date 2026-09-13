import MyPassKit

/// Presents, for `PasswordGeneratorView` and `PasswordRulesSummary`, the
/// answer `PasswordGenerator` gives to "what does this rule permit, given
/// these toggles?" -- it no longer decides that question itself.
///
/// It used to. Locked-on classes, locked-off classes and the permitted-set
/// check all lived here as this layer's own logic, while
/// `PasswordGenerator.effectivePool` answered the same question again for
/// generation. A whole-branch review found the two disagreeing in both
/// directions -- see the doc comment on `PasswordGenerator`'s
/// `permittedToggleClasses(for:)` in MyPassKit for the two concrete rules
/// (amundi-ee.com and classmates.com) that exposed it. The engine is now the
/// single authority; what remains here is the presentation-only part: naming
/// the classes in a stable display order, and the "your current selection
/// shares nothing with what this site permits" warning, which is a UI concern
/// with no equivalent inside the engine.
///
/// This type stays a plain, testable enum rather than a set of private
/// computed properties on the view, for the same reason `PasswordRulesSummary`
/// does: SwiftUI view state cannot be exercised directly by XCTest, and
/// `PasswordRulesToggleEvaluatorTests` covers the boundary cases a review
/// named.
enum PasswordRulesToggleEvaluator {
    /// The generator's four user-facing character-class toggles, named to
    /// match `PasswordGeneratorOptions`'s own field names (rather than
    /// `PasswordRules.CharacterClass`'s cases) since this is the shape the
    /// view's own `@State` already has.
    struct Toggles {
        var includeLowercase: Bool
        var includeUppercase: Bool
        var includeDigits: Bool
        var includeSymbols: Bool
    }

    struct Evaluation: Equatable {
        /// Classes the view locks ON regardless of the toggle, exactly as
        /// `PasswordGenerator.forcedOnToggleClasses(for:)` defines them --
        /// the rule's own `required:` clauses plus the sole-permitted-class
        /// case that `required:` alone does not cover.
        let lockedOn: Set<PasswordRules.CharacterClass>
        /// Classes the view locks OFF: the toggle-backed classes the rule
        /// excludes entirely, per
        /// `PasswordGenerator.excludedToggleClasses(for:)`.
        let lockedOff: Set<PasswordRules.CharacterClass>
        /// Non-empty exactly when the rule restricts the character set to
        /// two or more (but not all four) toggle-backed classes, no locked-on
        /// class already forces one of them on, and NONE of the caller's
        /// current `toggles` overlap that permitted set -- i.e. generation is
        /// guaranteed to fail with
        /// `PasswordGeneratorError.noCharacterClassSelected` given the
        /// current selection. Named in this type's own display order (see
        /// `toggleClassOrder`) so a caller can render the list directly.
        ///
        /// A permitted set of exactly ONE class is handled by locking that
        /// class on instead: it leaves the user no real choice to take away,
        /// whereas forcing a class on when two or more are permitted would
        /// take away a choice the user genuinely has. A permitted set of all
        /// four is not a restriction at all -- there is nothing to warn
        /// about, and "site X only allows lowercase letters, uppercase
        /// letters, digits and symbols" would be a nonsense sentence -- so
        /// that case is excluded too, the same threshold
        /// `PasswordRulesSummary` applies to its own permitted-set sentence.
        let conflictingWithAllowedClasses: [PasswordRules.CharacterClass]
    }

    /// Display order wherever a caller renders a list of the toggle-backed
    /// classes. Delegates to the engine's own list rather than declaring a
    /// second copy of "which four classes exist, and in what order."
    static var toggleClassOrder: [PasswordRules.CharacterClass] { PasswordGenerator.toggleBackedClasses }

    static func evaluate(rule: PasswordRules, toggles: Toggles) -> Evaluation {
        let lockedOn = PasswordGenerator.forcedOnToggleClasses(for: rule)
        let lockedOff = PasswordGenerator.excludedToggleClasses(for: rule)

        var conflict: [PasswordRules.CharacterClass] = []
        if let permitted = restrictedAllowedToggleClasses(for: rule),
           permitted.count >= 2,
           permitted.count < toggleClassOrder.count,
           lockedOn.isDisjoint(with: permitted) {
            let enabled = enabledClasses(in: toggles)
            if permitted.isDisjoint(with: enabled) {
                conflict = toggleClassOrder.filter { permitted.contains($0) }
            }
        }

        return Evaluation(lockedOn: lockedOn, lockedOff: lockedOff, conflictingWithAllowedClasses: conflict)
    }

    /// The toggle-backed classes the rule permits -- nil when the rule places
    /// no restriction there at all. A thin alias for
    /// `PasswordGenerator.permittedToggleClasses(for:)`, kept so this UI
    /// layer's two callers (`PasswordGeneratorView`'s conflict warning and
    /// `PasswordRulesSummary`'s permitted-set sentence) read the vocabulary
    /// of the surface they belong to; the answer itself comes from the
    /// engine.
    static func restrictedAllowedToggleClasses(for rule: PasswordRules) -> Set<PasswordRules.CharacterClass>? {
        PasswordGenerator.permittedToggleClasses(for: rule)
    }

    private static func enabledClasses(in toggles: Toggles) -> Set<PasswordRules.CharacterClass> {
        var enabled: Set<PasswordRules.CharacterClass> = []
        if toggles.includeLowercase { enabled.insert(.lower) }
        if toggles.includeUppercase { enabled.insert(.upper) }
        if toggles.includeDigits { enabled.insert(.digit) }
        if toggles.includeSymbols { enabled.insert(.special) }
        return enabled
    }
}
