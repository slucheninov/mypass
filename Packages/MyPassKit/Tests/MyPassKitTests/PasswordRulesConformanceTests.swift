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

        // 3 attempts per domain, not 1: a single lucky draw could pass by
        // chance even if the generator only satisfies a rule most of the
        // time rather than always. 3 x 436 domains = ~1,308 generations,
        // each a handful of in-memory character draws with no I/O and no
        // expensive key-derivation work (unlike, say, an Argon2
        // known-answer test) -- measured at 0.076-0.078s wall-clock over
        // several `swift test --filter PasswordRulesConformanceTests` runs
        // on the current tree, comfortably under a few seconds locally.
        let attemptsPerDomain = 3

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
