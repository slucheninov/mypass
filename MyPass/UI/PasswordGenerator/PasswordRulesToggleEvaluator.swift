import MyPassKit

/// Pure, testable rule-vs-toggle logic extracted from `PasswordGeneratorView`
/// for the same reason `PasswordRulesSummary` was extracted from it earlier
/// in the same task: SwiftUI view state and computed properties on a `View`
/// cannot be exercised directly by XCTest. This is exactly the logic a
/// Task 7 review turned on -- locked-on classes, locked-off classes, and
/// the allowed/enabled overlap check below -- so it now has its own direct
/// tests (`PasswordRulesToggleEvaluatorTests`) for the boundary cases the
/// review named, rather than only the inspection a private view property
/// allowed.
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
        /// Classes the view locks ON regardless of the toggle: the rule's
        /// own `required:` clauses, plus the one further case `required:`
        /// alone doesn't cover -- see `lockedOnClasses(for:)`'s doc
        /// comment.
        let lockedOn: Set<PasswordRules.CharacterClass>
        /// Classes the view locks OFF: the four toggle-backed classes the
        /// rule's effective allowed set excludes entirely.
        let lockedOff: Set<PasswordRules.CharacterClass>
        /// Non-empty exactly when the rule restricts `allowed:` to two or
        /// more (but not all four) toggle-backed classes, no `required:`
        /// clause already forces one of them on, and NONE of the caller's
        /// current `toggles` overlap that permitted set -- i.e.
        /// generation is guaranteed to fail with
        /// `PasswordGeneratorError.noCharacterClassSelected` given the
        /// current selection. Named in this type's own display order (see
        /// `toggleClassOrder`) so a caller can render the list directly.
        /// See `lockedOnClasses(for:)` for why a permitted set of exactly
        /// ONE class is instead handled by locking rather than by this
        /// conflict list: that case leaves the user no real choice to
        /// take away, this one does, and forcing a class on regardless of
        /// the user's own preference would take that choice away for a
        /// case where the user has an actual choice among two or more
        /// permitted classes.
        let conflictingWithAllowedClasses: [PasswordRules.CharacterClass]
    }

    /// Toggle-backed classes this evaluator reasons about, and their
    /// display order wherever a caller renders a list of them.
    private static let toggleClassOrder: [PasswordRules.CharacterClass] = [.lower, .upper, .digit, .special]

    static func evaluate(rule: PasswordRules, toggles: Toggles) -> Evaluation {
        let lockedOn = lockedOnClasses(for: rule)
        let lockedOff = lockedOffClasses(for: rule)

        var conflict: [PasswordRules.CharacterClass] = []
        if let restricted = restrictedAllowedToggleClasses(for: rule), restricted.count >= 2 {
            let enabled = enabledClasses(in: toggles)
            if restricted.isDisjoint(with: enabled) {
                conflict = toggleClassOrder.filter { restricted.contains($0) }
            }
        }

        return Evaluation(lockedOn: lockedOn, lockedOff: lockedOff, conflictingWithAllowedClasses: conflict)
    }

    /// The rule's own `allowed:` set, restricted to the four toggle-backed
    /// classes -- nil when the rule places no restriction there at all.
    /// `internal` (no access modifier) rather than `private`, specifically
    /// so `PasswordRulesSummary` can reuse this exact logic to decide
    /// whether its own permitted-set sentence applies, rather than
    /// re-deriving the same "what does `allowed:` actually restrict"
    /// question a second, potentially divergent way.
    ///
    /// Two cases both mean "no restriction, the user's toggles decide,"
    /// mirroring `PasswordGenerator.effectivePool`'s own
    /// `noExplicitAllowList` / `asciiPrintableInPlay` handling in
    /// MyPassKit: an EMPTY `allowedClasses` (no explicit `allowed:`
    /// property was present when the rule was parsed), and a set that
    /// explicitly names `.asciiPrintable` (Apple's grammar for "any of
    /// these four is fine"). `PasswordRulesParser` never actually produces
    /// the empty case today -- a rule with no `allowed:` property defaults
    /// to `[.asciiPrintable]` -- but relying on that as an unstated
    /// invariant here, rather than checking for it explicitly, was exactly
    /// the latent divergence between this view's logic and the engine a
    /// Task 7 review caught: this function keeps behaving correctly even
    /// if a rule value with a genuinely empty list ever reaches it.
    static func restrictedAllowedToggleClasses(for rule: PasswordRules) -> Set<PasswordRules.CharacterClass>? {
        guard !rule.allowedClasses.isEmpty, !rule.allowedClasses.contains(.asciiPrintable) else {
            return nil
        }
        return Set(toggleClassOrder).intersection(rule.allowedClasses)
    }

    /// Classes locked ON regardless of the user's own toggle: the rule's
    /// `required:` clauses (Decision 4 of the spec -- "a site that
    /// mandates a digit gets one even if the user turned digits off"),
    /// plus one further case `required:` alone doesn't cover.
    ///
    /// Some real vendored rules restrict the character set without
    /// requiring anything. amundi-ee.com's whole rule is "minlength: 6;
    /// maxlength: 6; allowed: digit; max-consecutive: 3" -- a six-digit
    /// PIN. There is no `required:` clause naming digits at all, but
    /// digits are the ONLY character this rule permits, so a user whose
    /// own saved defaults have digits turned off would otherwise sail
    /// through the generator screen with every toggle looking legitimate
    /// and only discover the conflict as an opaque
    /// `PasswordGeneratorError.noCharacterClassSelected` after pressing
    /// Generate.
    ///
    /// The fix: when the rule's `allowed:` set restricted to the four
    /// toggle-backed classes has EXACTLY ONE member, that member is locked
    /// on the same way a `required:` class already is. This is
    /// unconditional on the class's current toggle value (not "only lock
    /// it while it is currently off") specifically to avoid a flip-flop: a
    /// condition like "lock it only while nothing allowed is enabled"
    /// would unlock itself the instant this forced the toggle true,
    /// letting the user immediately turn it back off and recreate the
    /// exact same dead end.
    ///
    /// Deliberately NOT extended to a permitted set of two or more
    /// classes: there the user has a genuine choice among the permitted
    /// classes, and forcing one of them on regardless of the user's own
    /// preference would take that choice away. `evaluate(rule:toggles:)`'s
    /// `conflictingWithAllowedClasses` instead surfaces that broader case
    /// as a visible warning, without picking a class for the user.
    static func lockedOnClasses(for rule: PasswordRules) -> Set<PasswordRules.CharacterClass> {
        var locked = Set(rule.requiredClauses.flatMap { $0 })
        if let restricted = restrictedAllowedToggleClasses(for: rule), restricted.count == 1 {
            locked.formUnion(restricted)
        }
        return locked
    }

    /// The four toggle-backed classes the rule's effective allowed set
    /// excludes entirely -- empty when the rule places no restriction
    /// there (see `restrictedAllowedToggleClasses(for:)`, including the
    /// explicit empty-list handling documented there).
    static func lockedOffClasses(for rule: PasswordRules) -> Set<PasswordRules.CharacterClass> {
        guard let restricted = restrictedAllowedToggleClasses(for: rule) else { return [] }
        return Set(toggleClassOrder).subtracting(restricted)
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
