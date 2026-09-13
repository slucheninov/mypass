import XCTest
import MyPassKit
@testable import MyPass

/// Pins the separation between "the user's stored preference" and "the options
/// this one generation actually used".
///
/// The defect these tests exist for was the most serious on its branch:
/// `PasswordGeneratorView` overwrote its own toggle state with the active
/// site rule's decisions and then persisted THOSE values. That save site is
/// the only writer of `PasswordGeneratorDefaults`, and both the app's
/// generator and the extension bridge's `generatePassword` handler read it --
/// so one visit to a site with a restrictive rule silently narrowed the
/// character set of every password the user generated afterwards, for every
/// other site, with nothing in the UI revealing it.
final class PasswordGeneratorSessionTests: XCTestCase {
    private func makeThrowawaySuite(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: name)
        }
        return defaults
    }

    private func parse(_ raw: String) throws -> PasswordRules {
        guard case .success(let rules) = PasswordRulesParser.parse(raw) else {
            throw XCTSkip("expected \(raw) to parse")
        }
        return rules
    }

    /// amundi-ee.com's entire real rule from the vendored 2026-09-12 snapshot:
    /// a six-digit PIN. Using the generator once against it used to persist a
    /// digits-only, six-character default for everything.
    private let sixDigitPinRule = "minlength: 6; maxlength: 6; allowed: digit; max-consecutive: 3;"

    func testGeneratingAgainstARuleRestrictedSiteLeavesTheUsersDefaultsUntouched() throws {
        let defaults = makeThrowawaySuite("PasswordGeneratorSessionTests-restricted-site")
        let userOptions = PasswordGeneratorOptions(
            length: 24, includeLowercase: true, includeUppercase: true, includeDigits: false, includeSymbols: true
        )

        let password = try PasswordGeneratorSession.generate(
            userOptions: userOptions,
            rule: try parse(sixDigitPinRule),
            defaults: defaults
        )

        // The password honours the site: six characters, digits only, even
        // though the user had digits switched off.
        XCTAssertEqual(password.count, 6)
        XCTAssertTrue(password.allSatisfy { $0.isNumber }, "\(password) must be digits only")

        // The persisted defaults are the user's own, character for character.
        let stored = PasswordGeneratorDefaults.load(from: defaults)
        XCTAssertEqual(stored.length, 24)
        XCTAssertTrue(stored.includeLowercase)
        XCTAssertTrue(stored.includeUppercase)
        XCTAssertFalse(stored.includeDigits, "the site's sole-allowed class must not become a global default")
        XCTAssertTrue(stored.includeSymbols)
    }

    func testASecondGenerationWithNoRuleUsesTheUsersOwnDefaultsNotThePreviousSitesRule() throws {
        // The consequence the user actually experiences, spelled out as its
        // own test: the next password generated anywhere else must come from
        // the user's own alphabet, not from whatever the last site allowed.
        let defaults = makeThrowawaySuite("PasswordGeneratorSessionTests-next-site")
        let userOptions = PasswordGeneratorOptions(
            length: 24, includeLowercase: true, includeUppercase: true, includeDigits: false, includeSymbols: true
        )

        _ = try PasswordGeneratorSession.generate(
            userOptions: userOptions,
            rule: try parse(sixDigitPinRule),
            defaults: defaults
        )

        let reloaded = PasswordGeneratorDefaults.load(from: defaults)
        let next = try PasswordGeneratorSession.generate(userOptions: reloaded, rule: nil, defaults: defaults)
        XCTAssertEqual(next.count, 24)
        XCTAssertFalse(next.allSatisfy { $0.isNumber }, "\(next) came from the previous site's narrowed alphabet")
    }

    func testDeliberateUserChangesAreStillPersisted() throws {
        // The separation must not turn into "nothing is ever saved" -- the
        // generator's defaults exist so the user's own choice sticks.
        let defaults = makeThrowawaySuite("PasswordGeneratorSessionTests-user-change")
        let userOptions = PasswordGeneratorOptions(
            length: 30, includeLowercase: true, includeUppercase: false, includeDigits: true, includeSymbols: false
        )
        _ = try PasswordGeneratorSession.generate(userOptions: userOptions, rule: nil, defaults: defaults)

        let stored = PasswordGeneratorDefaults.load(from: defaults)
        XCTAssertEqual(stored.length, 30)
        XCTAssertTrue(stored.includeLowercase)
        XCTAssertFalse(stored.includeUppercase)
        XCTAssertTrue(stored.includeDigits)
        XCTAssertFalse(stored.includeSymbols)
    }
}
