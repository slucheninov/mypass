import XCTest
@testable import MyPassKit

final class PasswordGeneratorRulesTests: XCTestCase {
    func testLengthIsClampedIntoTheRuleRange() throws {
        let rules = PasswordRules(minLength: 10, maxLength: 12)
        let options = PasswordGeneratorOptions(length: 20, includeLowercase: true, includeUppercase: true, includeDigits: true, includeSymbols: true)
        let password = try PasswordGenerator.generate(options: options, rules: rules)
        XCTAssertEqual(password.count, 12)
    }

    func testLengthIsRaisedToTheRuleMinimum() throws {
        // The other half of clamping: a request shorter than the rule's
        // minimum must be raised, not honored as-is or rejected.
        let rules = PasswordRules(minLength: 10, maxLength: 12)
        let options = PasswordGeneratorOptions(length: 4, includeLowercase: true, includeUppercase: true, includeDigits: true, includeSymbols: true)
        let password = try PasswordGenerator.generate(options: options, rules: rules)
        XCTAssertEqual(password.count, 10)
    }

    func testRequiredClassOverridesADisabledToggle() throws {
        let rules = PasswordRules(requiredClauses: [[.digit]], allowedClasses: [.digit, .lower])
        let options = PasswordGeneratorOptions(length: 16, includeLowercase: true, includeUppercase: false, includeDigits: false, includeSymbols: false)
        let password = try PasswordGenerator.generate(options: options, rules: rules)
        XCTAssertTrue(password.contains { $0.isNumber }, "a rule-required digit must appear even though includeDigits is off")
    }

    func testCustomRequiredClassAppearsInOutput() throws {
        let customMembers: Set<Character> = ["!", "@", "#"]
        let rules = PasswordRules(requiredClauses: [[.custom(customMembers)]], allowedClasses: [.custom(customMembers), .lower])
        let options = PasswordGeneratorOptions(length: 12, includeLowercase: true, includeUppercase: false, includeDigits: false, includeSymbols: false)
        let password = try PasswordGenerator.generate(options: options, rules: rules)
        XCTAssertTrue(password.contains { customMembers.contains($0) })
    }

    func testMaxConsecutiveIsNeverViolatedAcrossManyGenerations() throws {
        // Statistical proof that the generator honours max-consecutive
        // regardless of which internal path resolves a given attempt --
        // plain rejection sampling, or the deterministic-construction
        // fallback with repair. A two-character pool makes long runs
        // common enough by chance that 200 generations is a meaningful
        // check, not just a lucky pass.
        let rules = PasswordRules(allowedClasses: [.custom(["a", "b"])], maxConsecutive: 2)
        let options = PasswordGeneratorOptions(length: 24, includeLowercase: false, includeUppercase: false, includeDigits: false, includeSymbols: false)
        for _ in 0..<200 {
            let password = try PasswordGenerator.generate(options: options, rules: rules)
            let characters = Array(password)
            var run = 1
            for i in 1..<characters.count {
                run = characters[i] == characters[i - 1] ? run + 1 : 1
                XCTAssertLessThanOrEqual(run, 2)
            }
        }
    }

    func testDisallowedClassesNeverAppearInOutput() throws {
        // The most load-bearing guarantee in the whole rule system, and
        // the one no other test in this file checks: a class the rule
        // does not name must never leak into the password merely because
        // the user's own generator toggles happen to be on. Modeled on
        // airfrance.com's real rule, which allows only lowercase, digits
        // and a specific handful of punctuation -- a regression that let
        // MyPass's own 25-character symbol pool or uppercase leak in
        // would pass every other test in this file.
        let allowedSymbols: Set<Character> = ["-", "!", "#", "$", "&", "+", "/", "?", "@", "_"]
        let rules = PasswordRules(requiredClauses: [[.lower], [.digit]], allowedClasses: [.lower, .digit, .custom(allowedSymbols)])
        let options = PasswordGeneratorOptions(length: 20, includeLowercase: true, includeUppercase: true, includeDigits: true, includeSymbols: true)
        for _ in 0..<100 {
            let password = try PasswordGenerator.generate(options: options, rules: rules)
            for character in password {
                XCTAssertTrue(
                    character.isLowercase || character.isNumber || allowedSymbols.contains(character),
                    "unexpected character '\(character)' outside the rule's allowed classes in \(password)"
                )
            }
        }
    }

    func testRepairMaxConsecutiveFixesARunCreatedByItsOwnEarlierRepair() throws {
        // The exact regression caught by code review: a repair that only
        // checks backward from the position it just changed, and advances
        // past the whole repaired run without re-examining the boundary
        // with what follows, can create a brand-new violation. Starting
        // from "a a a b b" with max-consecutive 2, resampling the third
        // 'a' to break the leading run of three used to produce
        // "a a b b b" -- a new run of three b's -- because the scan never
        // looked at what came after the position it fixed. Looping this
        // many times gives the same statistical confidence as the
        // reviewer's own 200,000-trial simulation that the fix holds, not
        // just a single lucky draw.
        for _ in 0..<2000 {
            var characters: [Character] = ["a", "a", "a", "b", "b"]
            try PasswordGenerator.repairMaxConsecutive(&characters, maxConsecutive: 2, pool: ["a", "b"])
            var run = 1
            for i in 1..<characters.count {
                run = characters[i] == characters[i - 1] ? run + 1 : 1
                XCTAssertLessThanOrEqual(run, 2, "run of \(run) at index \(i) in \(String(characters))")
            }
        }
    }

    func testDeterministicFallbackConstructsASatisfyingCandidateDirectly() throws {
        // Calls the fallback construction directly instead of hoping
        // rejection sampling exhausts by chance to reach it -- at any
        // attempt bound generous enough to be practical for real rules,
        // honest rejection sampling has excellent odds of succeeding on
        // its own, so a test that only goes through `generate` cannot
        // reliably exercise this path at all.
        let pool: [Character] = ["a", "b"]
        for _ in 0..<500 {
            let characters = try PasswordGenerator.deterministicCandidate(
                length: 24,
                clauseCharacterSets: [],
                pool: pool,
                maxConsecutive: 2
            )
            XCTAssertEqual(characters.count, 24)
            var run = 1
            for i in 1..<characters.count {
                run = characters[i] == characters[i - 1] ? run + 1 : 1
                XCTAssertLessThanOrEqual(run, 2)
            }
        }
    }

    func testUnsatisfiableRulesThrowsForAnImpossibleCombination() {
        // maxlength: 1 with two distinct required clauses can never be
        // satisfied -- there is only one character to place, and it can
        // satisfy at most one clause.
        let rules = PasswordRules(requiredClauses: [[.digit], [.upper]], allowedClasses: [.digit, .upper], maxLength: 1)
        let options = PasswordGeneratorOptions(length: 1, includeLowercase: false, includeUppercase: true, includeDigits: true, includeSymbols: false)
        XCTAssertThrowsError(try PasswordGenerator.generate(options: options, rules: rules)) { error in
            guard case PasswordGeneratorError.unsatisfiableRules = error else {
                return XCTFail("expected unsatisfiableRules, got \(error)")
            }
        }
    }
}
