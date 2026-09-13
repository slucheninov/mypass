import XCTest
import MyPassKit
@testable import MyPass

/// Direct tests for the locked/disallowed/conflict logic a Task 7 review
/// found untested -- it previously lived only as private computed
/// properties on `PasswordGeneratorView`, exercised (per that task's own
/// report) by inspection rather than by XCTest. Extracting it into
/// `PasswordRulesToggleEvaluator` makes these boundary cases directly
/// testable.
final class PasswordRulesToggleEvaluatorTests: XCTestCase {
    private func toggles(
        lowercase: Bool = true,
        uppercase: Bool = true,
        digits: Bool = true,
        symbols: Bool = true
    ) -> PasswordRulesToggleEvaluator.Toggles {
        PasswordRulesToggleEvaluator.Toggles(
            includeLowercase: lowercase,
            includeUppercase: uppercase,
            includeDigits: digits,
            includeSymbols: symbols
        )
    }

    func testLocksOnEveryClassARequiredClauseNames() throws {
        // Real rule from the vendored 2026-09-12 snapshot, account.samsung.com.
        let ruleString = "minlength: 8; maxlength: 15; max-consecutive: 3; required: digit; required: special; required: upper,lower;"
        guard case .success(let rule) = PasswordRulesParser.parse(ruleString) else {
            return XCTFail("expected a valid parse")
        }
        let locked = PasswordGenerator.forcedOnToggleClasses(for: rule)
        XCTAssertEqual(locked, [.digit, .special, .upper, .lower])
    }

    func testLocksOnTheSolePermittedClassRegardlessOfItsOwnToggleValue() throws {
        // Real rule from the vendored 2026-09-12 snapshot, amundi-ee.com --
        // a six-digit PIN with no `required:` clause at all, so only the
        // sole-permitted-class rule (not `required:`) can lock digits on.
        let ruleString = "minlength: 6; maxlength: 6; allowed: digit; max-consecutive: 3;"
        guard case .success(let rule) = PasswordRulesParser.parse(ruleString) else {
            return XCTFail("expected a valid parse")
        }
        // Deliberately unconditional: locking must not depend on whether
        // digits currently happen to be on or off, since a condition like
        // "lock it only while off" would unlock itself the instant this
        // forced the toggle true, letting the user immediately turn it
        // back off and recreate the same dead end.
        XCTAssertEqual(PasswordGenerator.forcedOnToggleClasses(for: rule), [.digit])
        let evaluationWithDigitsOff = PasswordRulesToggleEvaluator.evaluate(rule: rule, toggles: toggles(digits: false))
        XCTAssertEqual(evaluationWithDigitsOff.lockedOn, [.digit])
        let evaluationWithDigitsOn = PasswordRulesToggleEvaluator.evaluate(rule: rule, toggles: toggles(digits: true))
        XCTAssertEqual(evaluationWithDigitsOn.lockedOn, [.digit])
    }

    func testLocksOffClassesTheAllowedSetExcludes() throws {
        // Real rule from the vendored 2026-09-12 snapshot, pixnet.cc --
        // permits exactly two named classes and names no custom class at
        // all, so both digits and symbols must be locked off.
        let ruleString = "minlength: 4; maxlength: 16; allowed: lower, upper;"
        guard case .success(let rule) = PasswordRulesParser.parse(ruleString) else {
            return XCTFail("expected a valid parse")
        }
        XCTAssertEqual(PasswordGenerator.excludedToggleClasses(for: rule), [.digit, .special])
    }

    func testDoesNotLockSymbolsOffWhenACustomClassPermitsSome() throws {
        // Real rule from the vendored 2026-09-12 snapshot, aetna.com --
        // allows lower/upper/digit (upper and digit via `required:`, folded
        // into `allowedClasses`; lower via `allowed:`) plus the bespoke
        // custom class `[-_&#@]`. It never names `special`, and this
        // evaluator's predecessor therefore locked Symbols off and let
        // `PasswordRulesSummary` tell the user only letters and digits were
        // permitted -- while `PasswordGenerator` put those five characters
        // into every generated password regardless. The custom class is now
        // read for what it plainly says: this site permits some symbols, so
        // the toggle stays the user's to make.
        let ruleString = "minlength: 8; maxlength: 20; max-consecutive: 2; required: upper; required: digit; allowed: lower, [-_&#@];"
        guard case .success(let rule) = PasswordRulesParser.parse(ruleString) else {
            return XCTFail("expected a valid parse")
        }
        XCTAssertEqual(PasswordGenerator.excludedToggleClasses(for: rule), [])
        XCTAssertEqual(
            PasswordRulesToggleEvaluator.restrictedAllowedToggleClasses(for: rule),
            [.lower, .upper, .digit, .special]
        )
    }

    func testFlagsAConflictWhenEnabledTogglesShareNothingWithATwoClassAllowedSet() throws {
        // Real rule from the vendored 2026-09-12 snapshot, pixnet.cc --
        // permits exactly two classes (lower, upper) with no `required:`
        // clause at all, so neither is locked on by the sole-class rule,
        // and a user who enables only digits/symbols walks into the exact
        // dead end this conflict check exists to catch before Generate is
        // pressed.
        let ruleString = "minlength: 4; maxlength: 16; allowed: lower, upper;"
        guard case .success(let rule) = PasswordRulesParser.parse(ruleString) else {
            return XCTFail("expected a valid parse")
        }
        let evaluation = PasswordRulesToggleEvaluator.evaluate(
            rule: rule,
            toggles: toggles(lowercase: false, uppercase: false, digits: true, symbols: true)
        )
        XCTAssertEqual(evaluation.conflictingWithAllowedClasses, [.lower, .upper])
        // Neither class is required, so nothing is forced on -- the whole
        // point of this check is that a dead end is still reachable
        // without a locked toggle to prevent it.
        XCTAssertEqual(evaluation.lockedOn, [])
    }

    func testNoConflictWhenAtLeastOneEnabledToggleOverlapsTheAllowedSet() throws {
        // Same pixnet.cc rule as above, but with lowercase left on --
        // enough overlap with the permitted set that generation is not a
        // guaranteed dead end, so no warning should fire.
        let ruleString = "minlength: 4; maxlength: 16; allowed: lower, upper;"
        guard case .success(let rule) = PasswordRulesParser.parse(ruleString) else {
            return XCTFail("expected a valid parse")
        }
        let evaluation = PasswordRulesToggleEvaluator.evaluate(
            rule: rule,
            toggles: toggles(lowercase: true, uppercase: false, digits: false, symbols: false)
        )
        XCTAssertEqual(evaluation.conflictingWithAllowedClasses, [])
    }

    func testEmptyAllowedListIsTreatedAsNoRestrictionNotAsNothingAllowed() throws {
        // `PasswordRulesParser` never actually produces an empty
        // `allowedClasses` today -- a rule with no `allowed:` property
        // defaults to `[.asciiPrintable]` -- but relying on that as an
        // unstated invariant, rather than handling it explicitly the way
        // `PasswordGenerator.effectivePool` already does for its own
        // `noExplicitAllowList` case, was exactly the latent divergence a
        // Task 7 review caught. This simulates the case the parser itself
        // never produces (via direct mutation of `allowedClasses`, a
        // public `var`) to prove the evaluator does not treat "no
        // information" as "nothing is allowed."
        guard case .success(var rule) = PasswordRulesParser.parse("minlength: 6; maxlength: 16;") else {
            return XCTFail("expected a valid parse")
        }
        rule.allowedClasses = []
        XCTAssertNil(PasswordRulesToggleEvaluator.restrictedAllowedToggleClasses(for: rule))
        XCTAssertEqual(PasswordGenerator.excludedToggleClasses(for: rule), [])
        XCTAssertEqual(PasswordGenerator.forcedOnToggleClasses(for: rule), [])
    }
}
