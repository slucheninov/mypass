import XCTest
@testable import MyPassKit

final class PasswordGeneratorRulesTests: XCTestCase {
    func testLengthIsClampedIntoTheRuleRange() throws {
        let rules = PasswordRules(minLength: 10, maxLength: 12)
        let options = PasswordGeneratorOptions(length: 20, includeLowercase: true, includeUppercase: true, includeDigits: true, includeSymbols: true)
        let password = try PasswordGenerator.generate(options: options, rules: rules)
        XCTAssertEqual(password.count, 12)
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
