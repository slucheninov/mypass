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

    // `save` always writes all five keys together, so it cannot produce a
    // suite where only some keys are present -- these two tests write the
    // raw keys directly to pin each key's independent absent-vs-stored
    // guard. Without the `object(forKey:) as? T` pattern in `load`, a
    // lookup that used `integer(forKey:)`/`bool(forKey:)` instead would
    // still pass `testAbsentValuesYieldTheDocumentedDefaults` and
    // `testRoundTripsSavedValues` above, because those two tests only ever
    // present a suite that is either fully empty or fully populated.

    func testOnlyLengthStoredStillYieldsDefaultClassFlags() {
        let defaults = makeThrowawaySuite("PasswordGeneratorDefaultsTests-partial-length-only")
        defaults.set(12, forKey: PasswordGeneratorDefaults.lengthKey)
        let options = PasswordGeneratorDefaults.load(from: defaults)
        XCTAssertEqual(options.length, 12)
        XCTAssertTrue(options.includeLowercase)
        XCTAssertTrue(options.includeUppercase)
        XCTAssertTrue(options.includeDigits)
        XCTAssertTrue(options.includeSymbols)
    }

    func testOnlyClassFlagsStoredStillYieldsDefaultLength() {
        let defaults = makeThrowawaySuite("PasswordGeneratorDefaultsTests-partial-flags-only")
        defaults.set(true, forKey: PasswordGeneratorDefaults.includeLowercaseKey)
        defaults.set(true, forKey: PasswordGeneratorDefaults.includeUppercaseKey)
        defaults.set(false, forKey: PasswordGeneratorDefaults.includeDigitsKey)
        defaults.set(true, forKey: PasswordGeneratorDefaults.includeSymbolsKey)
        let options = PasswordGeneratorDefaults.load(from: defaults)
        XCTAssertEqual(options.length, 20)
        XCTAssertTrue(options.includeLowercase)
        XCTAssertTrue(options.includeUppercase)
        XCTAssertFalse(options.includeDigits)
        XCTAssertTrue(options.includeSymbols)
    }
}
