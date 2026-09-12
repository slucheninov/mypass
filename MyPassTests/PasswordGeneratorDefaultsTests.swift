import XCTest
import MyPassKit
@testable import MyPass

final class PasswordGeneratorDefaultsTests: XCTestCase {
    private func makeThrowawaySuite(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        // Throwaway suites still land on disk under this name; tear the
        // persistent domain down again after the test so no leftover
        // plist accumulates on the machine running the suite.
        addTeardownBlock {
            defaults.removePersistentDomain(forName: name)
        }
        return defaults
    }

    func testAbsentValuesYieldTheDocumentedDefaults() {
        let defaults = makeThrowawaySuite("PasswordGeneratorDefaultsTests-absent")
        let options = PasswordGeneratorDefaults.load(from: defaults)
        XCTAssertEqual(options.length, 20)
        XCTAssertTrue(options.includeLowercase)
        XCTAssertTrue(options.includeUppercase)
        XCTAssertTrue(options.includeDigits)
        XCTAssertTrue(options.includeSymbols)
    }

    func testRoundTripsSavedValues() {
        let defaults = makeThrowawaySuite("PasswordGeneratorDefaultsTests-roundtrip")
        let saved = PasswordGeneratorOptions(
            length: 32, includeLowercase: false, includeUppercase: true, includeDigits: false, includeSymbols: true
        )
        PasswordGeneratorDefaults.save(saved, to: defaults)
        let loaded = PasswordGeneratorDefaults.load(from: defaults)
        XCTAssertEqual(loaded.length, 32)
        XCTAssertFalse(loaded.includeLowercase)
        XCTAssertTrue(loaded.includeUppercase)
        XCTAssertFalse(loaded.includeDigits)
        XCTAssertTrue(loaded.includeSymbols)
    }
}
