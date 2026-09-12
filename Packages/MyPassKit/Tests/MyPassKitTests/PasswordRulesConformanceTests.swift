import XCTest
@testable import MyPassKit

final class PasswordRulesConformanceTests: XCTestCase {
    /// All four baseline toggles on, so the effective pool is never
    /// artificially starved by a toggle the rule didn't ask about -- this
    /// test exists to prove the PARSER and GENERATOR agree with each other
    /// and with real-world data, not to exercise toggle interaction (Task
    /// 4's `PasswordGeneratorRulesTests` already covers that).
    private static let allTogglesOn = PasswordGeneratorOptions(
        length: 20, includeLowercase: true, includeUppercase: true, includeDigits: true, includeSymbols: true
    )

    func testEveryVendoredRuleGeneratesConformingPasswords() throws {
        let data = PasswordRulesResource.rawJSON
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [String: String]])

        // More than 1 attempt per domain: a single lucky draw could pass
        // by chance even if the generator only satisfies a rule most of
        // the time rather than always. But 3 was too thin to trust: if a
        // defect made the generator violate a tight rule 2% of the time,
        // 3 attempts miss it with probability 0.98^3 ~= 94.12%, i.e. it
        // is CAUGHT only ~5.88% of the time -- worse than a coin flip.
        // Raising to 40 attempts (0.98^40 ~= 44.57% miss rate, so ~55.43%
        // caught against that same 2% defect) roughly triples the
        // detection rate against a defect this small, though it is still
        // no guarantee -- a defect that rare would need a great many more
        // attempts than fit in a test suite people are expected to run
        // habitually, so this is a deliberate, documented trade of
        // runtime against confidence, not a claim of exhaustive coverage.
        // 40 x 436 domains = 17,440 generations, each a handful of
        // in-memory character draws with no I/O and no expensive
        // key-derivation work (unlike, say, an Argon2 known-answer
        // test) -- measured at 1.20-1.23s wall-clock over several
        // `swift test --filter PasswordRulesConformanceTests` runs on
        // the current tree (previously 0.076-0.078s at 3 attempts, i.e.
        // ~59us/generation: 0.077s / 1,308 generations -- close to the
        // 17,440 x 59us ~= 1.03s this would predict; the extra ~200ms is
        // plausibly the per-character allowed-set check added alongside
        // this attempt count, which the 3-attempt measurement predates).
        let attemptsPerDomain = 40

        for (domain, entry) in raw {
            guard let ruleString = entry["password-rules"] else {
                XCTFail("\(domain): vendored entry missing password-rules key")
                continue
            }
            guard case .success(let rules) = PasswordRulesParser.parse(ruleString) else {
                XCTFail("\(domain): failed to parse vendored rule \(ruleString)")
                continue
            }

            for attempt in 0..<attemptsPerDomain {
                let password: String
                do {
                    password = try PasswordGenerator.generate(options: Self.allTogglesOn, rules: rules)
                } catch {
                    XCTFail("\(domain) attempt \(attempt): generate(options:rules:) threw \(error) for rule \(ruleString)")
                    continue
                }
                assertConforms(password, to: rules, domain: domain, ruleString: ruleString)
            }
        }
    }

    /// The two correctness properties of the `allowedClasses` check in
    /// `assertConforms` below cannot be verified against the 436 real
    /// vendored rules: a diagnostic sweep over the whole parsed dataset
    /// (not committed -- run once to confirm this, then discarded) found
    /// zero rules with an empty `allowedClasses` and zero rules where a
    /// required class was not already present in `allowedClasses`,
    /// because `PasswordRulesParser` always defaults an absent `allowed:`
    /// to `[.asciiPrintable]` and always folds every required class into
    /// `allowedClasses` before this test ever sees the rule (see
    /// `PasswordRulesParser.swift` and the doc comment on
    /// `PasswordRules.allowedClasses`). A bug in this test's own check --
    /// the union missing or backwards, or the empty-list branch inverted
    /// -- would therefore pass all 436 real domains silently: exactly the
    /// "might never show up" risk raised in review. These two rules,
    /// built directly and bypassing the parser's folding, close that
    /// blind spot.
    func testAllowedClassCheckTreatsARequiredClassAsImplicitlyAllowed() {
        let rules = PasswordRules(requiredClauses: [[.upper]], allowedClasses: [.lower], minLength: 4, maxLength: 4)
        assertConforms("Abcd", to: rules, domain: "synthetic.allowed-union-test", ruleString: "synthetic")
    }

    func testAllowedClassCheckTreatsAnEmptyAllowListAsNoRestriction() {
        let rules = PasswordRules(requiredClauses: [], allowedClasses: [], minLength: 4, maxLength: 4)
        assertConforms("!!!!", to: rules, domain: "synthetic.empty-allowed-test", ruleString: "synthetic")
    }

    private func assertConforms(_ password: String, to rules: PasswordRules, domain: String, ruleString: String) {
        let characters = Array(password)
        let context = "\(domain): \(ruleString) -> \(password)"

        if let minLength = rules.minLength {
            XCTAssertGreaterThanOrEqual(characters.count, minLength, context)
        }
        if let maxLength = rules.maxLength {
            XCTAssertLessThanOrEqual(characters.count, maxLength, context)
        }
        if let maxConsecutive = rules.maxConsecutive, characters.count > 1 {
            var run = 1
            for i in 1..<characters.count {
                run = characters[i] == characters[i - 1] ? run + 1 : 1
                XCTAssertLessThanOrEqual(run, maxConsecutive, context)
            }
        }
        for clause in rules.requiredClauses {
            let satisfied = characters.contains { character in
                clause.contains { matches(character, $0) }
            }
            XCTAssertTrue(satisfied, "\(context) -- required clause \(clause) not satisfied")
        }

        // `allowed:` confines the WHOLE password to specific classes --
        // e.g. `allowed: digit;` alone means every character must be a
        // digit. Nothing above checks this: minLength/maxLength/
        // maxConsecutive/requiredClauses would all still pass for a
        // password containing a class the site forbids, if a defect in
        // the generator's pool construction ever let one in. That is
        // exactly the guarantee this rule system exists to provide, so
        // it gets its own independent check here, deliberately NOT
        // calling into `PasswordGenerator`'s own internal verification
        // (which has just had the equivalent check added as an in-product
        // safety net) -- two copies of the same logic sharing an
        // implementation would put this test back to checking the
        // generator against itself.
        //
        // Two things this must get right or it is worse than not checking
        // at all:
        // - An EMPTY `allowedClasses` means the rule expressed no opinion
        //   on allowed characters at all, not "no characters allowed".
        //   `PasswordRulesParser` in practice always defaults a rule with
        //   no `allowed:` property to `[.asciiPrintable]` rather than
        //   leaving it empty, so this branch is a defensive floor for a
        //   `PasswordRules` built directly rather than something the 436
        //   vendored rules exercise -- but getting it backwards here would
        //   reject most of the catalog, not none of it.
        // - A class a rule REQUIRES is also implicitly ALLOWED even when
        //   `allowed:` does not separately name it -- real example from
        //   the vendored data, benjerry.com: `required: upper; required:
        //   digit; required: special; allowed: lower;`. Skipping this
        //   union would flag the very characters the rule mandates as
        //   violations; that mistake would only ever surface on a rule
        //   shaped exactly like this one, so it is easy to get wrong and
        //   have it go unnoticed.
        if !rules.allowedClasses.isEmpty {
            let effectiveAllowed = Set(rules.allowedClasses).union(rules.requiredClauses.flatMap { $0 })
            for character in characters {
                let permitted = effectiveAllowed.contains { matches(character, $0) }
                XCTAssertTrue(permitted, "\(context) -- character '\(character)' not in effective allowed set \(effectiveAllowed)")
            }
        }
    }

    /// A SECOND, independent characterization of each `CharacterClass`,
    /// deliberately not calling into `PasswordGenerator`'s own private
    /// `EffectivePool` -- if this test reused the generator's own
    /// membership logic, a bug shared by both would be invisible to it.
    private func matches(_ character: Character, _ characterClass: PasswordRules.CharacterClass) -> Bool {
        switch characterClass {
        case .upper: return character.isUppercase
        case .lower: return character.isLowercase
        case .digit: return character.isNumber
        case .special: return !character.isLetter && !character.isNumber
        case .asciiPrintable:
            guard let ascii = character.asciiValue else { return false }
            return ascii >= 0x20 && ascii <= 0x7E
        case .unicode: return true
        case .custom(let members): return members.contains(character)
        }
    }
}
