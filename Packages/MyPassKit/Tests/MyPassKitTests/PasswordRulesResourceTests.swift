import XCTest
@testable import MyPassKit

final class PasswordRulesResourceTests: XCTestCase {
    /// Sanity check that the vendored resource is actually bundled and
    /// readable, before anything in Task 2 or Task 3 depends on it.
    func testBundledPasswordRulesResourceLoadsAndParses() throws {
        let data = PasswordRulesResource.rawJSON
        let parsed = try JSONSerialization.jsonObject(with: data)
        let object = try XCTUnwrap(parsed as? [String: Any])

        // Deliberately NOT hardcoded to 436: `scripts/update-password-rules.sh`
        // (this task, Step 8) is expected to change this count on every
        // refresh as upstream adds or removes quirks. 100 is a floor that
        // only ever fails if the vendored file were replaced with
        // something close to empty by mistake -- the real count at
        // vendoring time (2026-09-12, commit 6073487115b7) is 436.
        XCTAssertGreaterThan(object.count, 100)
    }
}
