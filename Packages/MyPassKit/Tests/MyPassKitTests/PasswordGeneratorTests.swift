import XCTest
@testable import MyPassKit

final class PasswordGeneratorTests: XCTestCase {
    func testGeneratesRequestedLength() throws {
        let options = PasswordGeneratorOptions(length: 24, includeLowercase: true, includeUppercase: true, includeDigits: true, includeSymbols: true)
        let password = try PasswordGenerator.generate(options: options)
        XCTAssertEqual(password.count, 24)
    }

    func testOnlyDigitsProducesOnlyDigitCharacters() throws {
        let options = PasswordGeneratorOptions(length: 16, includeLowercase: false, includeUppercase: false, includeDigits: true, includeSymbols: false)
        let password = try PasswordGenerator.generate(options: options)
        XCTAssertTrue(password.allSatisfy { $0.isNumber })
    }

    func testNoCharacterClassThrows() {
        let options = PasswordGeneratorOptions(length: 16, includeLowercase: false, includeUppercase: false, includeDigits: false, includeSymbols: false)
        XCTAssertThrowsError(try PasswordGenerator.generate(options: options)) { error in
            guard case PasswordGeneratorError.noCharacterClassSelected = error else {
                return XCTFail("expected noCharacterClassSelected, got \(error)")
            }
        }
    }

    func testTwoGeneratedPasswordsDiffer() throws {
        let options = PasswordGeneratorOptions(length: 32, includeLowercase: true, includeUppercase: true, includeDigits: true, includeSymbols: true)
        let a = try PasswordGenerator.generate(options: options)
        let b = try PasswordGenerator.generate(options: options)
        XCTAssertNotEqual(a, b)
    }

    func testZeroLengthProducesEmptyString() throws {
        let options = PasswordGeneratorOptions(length: 0, includeLowercase: true, includeUppercase: false, includeDigits: false, includeSymbols: false)
        let password = try PasswordGenerator.generate(options: options)
        XCTAssertEqual(password, "")
    }

    func testEachSelectedClassCanAppearAcrossManyGenerations() throws {
        // Statistical sanity check: with all four classes enabled and enough
        // generated characters, every class should show up at least once.
        // This guards against a broken/biased mapping that only ever draws
        // from one class.
        let options = PasswordGeneratorOptions(length: 64, includeLowercase: true, includeUppercase: true, includeDigits: true, includeSymbols: true)
        let password = try PasswordGenerator.generate(options: options)
        XCTAssertTrue(password.contains { $0.isLowercase })
        XCTAssertTrue(password.contains { $0.isUppercase })
        XCTAssertTrue(password.contains { $0.isNumber })
        XCTAssertTrue(password.contains { !$0.isLetter && !$0.isNumber })
    }
}
