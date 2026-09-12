import XCTest
import MyPassKit
@testable import MyPass

final class PasswordRulesSummaryTests: XCTestCase {
    func testDescribesRequiredClassesLengthAndMaxConsecutive() throws {
        // Real rule from the vendored 2026-09-12 snapshot, account.samsung.com.
        let ruleString = "minlength: 8; maxlength: 15; max-consecutive: 3; required: digit; required: special; required: upper,lower;"
        guard case .success(let rules) = PasswordRulesParser.parse(ruleString) else {
            return XCTFail("expected a valid parse")
        }
        let summary = PasswordRulesSummary.describe(rules, domain: "account.samsung.com")
        XCTAssertEqual(
            summary,
            "account.samsung.com needs a digit, a symbol, an uppercase letter or a lowercase letter, 8 to 15 characters, at most 3 repeated characters in a row."
        )
    }

    func testDescribesALengthOnlyRule() throws {
        // Real rule from the vendored 2026-09-12 snapshot, 163.com.
        let ruleString = "minlength: 6; maxlength: 16;"
        guard case .success(let rules) = PasswordRulesParser.parse(ruleString) else {
            return XCTFail("expected a valid parse")
        }
        let summary = PasswordRulesSummary.describe(rules, domain: "163.com")
        XCTAssertEqual(summary, "163.com needs 6 to 16 characters.")
    }
}
