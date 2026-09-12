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

    func testLengthIsClampedToAMaximumWhenTheRuleStatesNoMinimum() throws {
        // The exact regression Task 5's conformance run found: a rule
        // stating only `maxlength` (e.g. bhphotovideo.com's entire rule is
        // literally "maxlength: 15") used to default the absent minimum
        // to the CALLER's requested length before comparing bounds, which
        // compared the request against the site's maximum instead of the
        // rule's own bounds against each other, and threw
        // `unsatisfiableRules` for a request longer than the maximum --
        // a rule that is trivially satisfiable by clamping down. This is
        // Decision 4's own worked example of correct behavior: a
        // twenty-character request against a maximum of twelve produces
        // a twelve-character password.
        let rules = PasswordRules(maxLength: 12)
        let options = PasswordGeneratorOptions(length: 20, includeLowercase: true, includeUppercase: true, includeDigits: true, includeSymbols: true)
        let password = try PasswordGenerator.generate(options: options, rules: rules)
        XCTAssertEqual(password.count, 12)
    }

    func testLengthIsRaisedToAMinimumWhenTheRuleStatesNoMaximum() throws {
        // The mirror image of the maximum-only case above: a rule stating
        // only `minlength` used to default the absent maximum to the
        // caller's requested length, which happened not to misfire for
        // this direction (raising a short request can never exceed a
        // maximum that isn't there), but the fix applies both bounds
        // independently, so this is covered directly rather than by
        // inference from the maximum-only case.
        let rules = PasswordRules(minLength: 10)
        let options = PasswordGeneratorOptions(length: 4, includeLowercase: true, includeUppercase: true, includeDigits: true, includeSymbols: true)
        let password = try PasswordGenerator.generate(options: options, rules: rules)
        XCTAssertEqual(password.count, 10)
    }

    func testGenuinelyInvertedLengthRangeThrows() {
        // A rule that states BOTH bounds, with the minimum actually
        // exceeding the maximum, must still be treated as unsatisfiable --
        // the fix narrows the inversion check to fire only when both
        // bounds are stated, it must not stop firing when they truly are
        // inverted.
        let rules = PasswordRules(minLength: 12, maxLength: 10)
        let options = PasswordGeneratorOptions(length: 11, includeLowercase: true, includeUppercase: true, includeDigits: true, includeSymbols: true)
        XCTAssertThrowsError(try PasswordGenerator.generate(options: options, rules: rules)) { error in
            guard case PasswordGeneratorError.unsatisfiableRules = error else {
                return XCTFail("expected unsatisfiableRules, got \(error)")
            }
        }
    }

    func testVivoComBrShapedRuleIsSatisfied() throws {
        // vivo.com.br's real vendored rule is literally
        // "maxlength: 6; max-consecutive: 3; allowed: digit" -- six
        // digits, no more than three of the same in a row, drawn from a
        // ten-character pool. It exercises the length clamp (maximum
        // only, no minimum -- the exact shape of all seven domains Task
        // 5's conformance run flagged), the restricted pool, and the
        // consecutive limit together, so it is the best single regression
        // case among them.
        let rules = PasswordRules(allowedClasses: [.digit], maxLength: 6, maxConsecutive: 3)
        let options = PasswordGeneratorOptions(length: 16, includeLowercase: true, includeUppercase: true, includeDigits: true, includeSymbols: true)
        for _ in 0..<200 {
            let password = try PasswordGenerator.generate(options: options, rules: rules)
            XCTAssertEqual(password.count, 6)
            let characters = Array(password)
            var run = 1
            for character in characters {
                XCTAssertTrue(character.isNumber, "unexpected non-digit character '\(character)' in \(password)")
            }
            for i in 1..<characters.count {
                run = characters[i] == characters[i - 1] ? run + 1 : 1
                XCTAssertLessThanOrEqual(run, 3, "run of \(run) at index \(i) in \(password)")
            }
        }
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

    func testDeterministicFallbackSatisfiesEachRequiredClauseDirectly() throws {
        // The sibling test above passes an empty clause list, so it never
        // exercised the anchor-placement half of `deterministicCandidate`
        // -- the part that actually guarantees a required clause is met.
        // Round 2 review flagged this gap; the call at the time was to
        // leave it because Task 5's conformance run against 436 real
        // rules would exercise required clauses in volume. Task 5 later
        // reported it could not confirm the fallback path fired at all
        // during that run, so that reasoning bought nothing -- this is
        // the direct test that should have been here from the start.
        let digitPool: [Character] = Array("0123456789")
        let upperPool: [Character] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let clauseCharacterSets: [[Character]] = [digitPool, upperPool]
        let fullPool = Array(Set(digitPool + upperPool))
        for _ in 0..<200 {
            let characters = try PasswordGenerator.deterministicCandidate(
                length: 12,
                clauseCharacterSets: clauseCharacterSets,
                pool: fullPool,
                maxConsecutive: nil
            )
            XCTAssertEqual(characters.count, 12)
            XCTAssertTrue(characters.contains { digitPool.contains($0) }, "missing the digit-clause anchor in \(String(characters))")
            XCTAssertTrue(characters.contains { upperPool.contains($0) }, "missing the uppercase-clause anchor in \(String(characters))")
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
        // 257 (used in the sibling range test above) is the WORST
        // possible modulus for detecting a missing rejection step: the
        // 65536-value draw range divides as 65536 = 255*257 + 1, so a
        // naive `value % modulus` without rejection would only
        // over-count a single remainder by one raw value out of 65536 --
        // an expected excess of about one draw against a per-bucket
        // standard deviation around seventeen, invisible at any practical
        // sample size. That was round 2's mistake in this file.
        //
        // 40000 makes the effect large and exact instead of negligible.
        // The accepted range under correct rejection sampling is
        // `limit = 65536 - (65536 % 40000) = 65536 - 25536 = 40000`,
        // i.e. exactly one full cycle of 0..<40000 -- 65536 < 2*40000, so
        // that is also the largest multiple of 40000 not exceeding
        // 65536. Under CORRECT rejection sampling, every remainder in
        // 0..<40000 is produced by exactly one raw draw value (itself),
        // so the "low" remainders 0..<25536 and the "high" remainders
        // 25536..<40000 occur at the same rate.
        //
        // Under a BROKEN implementation with the rejection step deleted
        // (`value % modulus` over the full, unrejected 0..<65536 range),
        // remainder r is produced by raw value r, AND by raw value
        // r + 40000 whenever that second value is still under 65536 --
        // true exactly when r < 65536 - 40000 = 25536. So every "low"
        // remainder (0..<25536) is produced by two raw values, and every
        // "high" remainder (25536..<40000) by only one: the low group's
        // rate is EXACTLY double the high group's, a large, deterministic
        // signal rather than a one-part-in-65536 artifact.
        //
        // The test below draws many samples and compares the average
        // rate per bucket in the low group against the high group. A
        // correct implementation gives a ratio of 1; the broken one
        // described above gives a ratio of 2. The bounds (0.8...1.3) are
        // generous relative to the actual sampling variance at this
        // trial count (each group's count has a relative standard
        // deviation under 0.2%, so a correct implementation's ratio sits
        // within a fraction of a percent of 1.0 in practice) while
        // leaving no room for the broken implementation's ratio of 2 to
        // sneak through.
        let modulus = 40000
        let lowUpperBoundExclusive = 65536 % modulus // 25536: remainders doubled if rejection is missing
        let lowBucketCount = lowUpperBoundExclusive
        let highBucketCount = modulus - lowUpperBoundExclusive // 14464
        var lowCount = 0
        var highCount = 0
        let trials = 200_000
        for _ in 0..<trials {
            let value = try PasswordGenerator.secureRandomIndexWide(modulo: modulus)
            XCTAssertLessThan(value, modulus)
            if value < lowUpperBoundExclusive {
                lowCount += 1
            } else {
                highCount += 1
            }
        }
        let lowRate = Double(lowCount) / Double(lowBucketCount)
        let highRate = Double(highCount) / Double(highBucketCount)
        let ratio = lowRate / highRate
        XCTAssertGreaterThan(ratio, 0.8, "low/high rate ratio \(ratio) is too skewed for a correct implementation")
        XCTAssertLessThan(ratio, 1.3, "low/high rate ratio \(ratio) is consistent with a missing rejection step (expected ~2.0 if broken, ~1.0 if correct)")
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
