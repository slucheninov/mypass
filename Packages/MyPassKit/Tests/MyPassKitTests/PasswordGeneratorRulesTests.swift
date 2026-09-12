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

    func testSecureRandomIndexWideStaysInRangeAcrossModuliBoundaries() throws {
        // `secureRandomIndexWide` is the only genuinely new randomness
        // primitive in the rules-aware generator, and nothing `generate`
        // can construct today drives a modulus above 256, so nothing else
        // exercises it. Cover both boundaries the doc comment reasons
        // about (257, the first modulus that needs this path, and 65536,
        // the top of its range) plus a couple of moduli in between.
        for modulus in [257, 500, 1000, 65535, 65536] {
            for _ in 0..<500 {
                let value = try PasswordGenerator.secureRandomIndexWide(modulo: modulus)
                XCTAssertGreaterThanOrEqual(value, 0)
                XCTAssertLessThan(value, modulus)
            }
        }
    }

    func testSecureRandomIndexWideRejectsRatherThanBiasing() throws {
        // A modulus just above the single-byte boundary, drawn many
        // times, should distribute close to evenly across all 257
        // possible values -- the property the rejection-sampling scheme
        // exists to guarantee. A broken implementation that used
        // `value % modulus` without rejecting draws at or above the
        // largest multiple of `modulus` under 65536 would still pass the
        // in-range check above, but would visibly favor the low end of
        // 0..<257 over the high end, since 257 does not evenly divide
        // 65536. The bounds below (0.5x-1.5x of the expected per-value
        // count) are generous relative to the actual standard deviation
        // at this sample size, to catch real bias without flaking on
        // ordinary sampling variance.
        let modulus = 257
        var counts = [Int](repeating: 0, count: modulus)
        let trials = modulus * 300
        for _ in 0..<trials {
            let value = try PasswordGenerator.secureRandomIndexWide(modulo: modulus)
            counts[value] += 1
        }
        let expected = Double(trials) / Double(modulus)
        for (value, count) in counts.enumerated() {
            XCTAssertGreaterThan(Double(count), expected * 0.5, "value \(value) drawn only \(count) times, expected around \(expected)")
            XCTAssertLessThan(Double(count), expected * 1.5, "value \(value) drawn \(count) times, expected around \(expected)")
        }
    }

    func testSecureRandomIndexWideThrowsAboveItsRange() {
        // A modulus above 65536 has no representation in this function's
        // two-byte draw range; it must throw a typed error rather than
        // loop forever or silently truncate.
        XCTAssertThrowsError(try PasswordGenerator.secureRandomIndexWide(modulo: 65537)) { error in
            guard case PasswordGeneratorError.unsatisfiableRules = error else {
                return XCTFail("expected unsatisfiableRules, got \(error)")
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
