import XCTest
import SwiftUI
import AppKit
@testable import MyPass

final class LetterAvatarTests: XCTestCase {
    func testLetterFromNonEmptyTitle() {
        XCTAssertEqual(LetterAvatar.letter(from: "GitHub"), "G")
        XCTAssertEqual(LetterAvatar.letter(from: "amazon"), "A")
    }

    func testLetterFromEmptyOrWhitespaceTitle() {
        XCTAssertEqual(LetterAvatar.letter(from: ""), "?")
        XCTAssertEqual(LetterAvatar.letter(from: "   "), "?")
    }

    func testColorIsDeterministicForSameTitle() {
        let first = rgbaComponents(LetterAvatar.color(for: "Example Service"))
        let second = rgbaComponents(LetterAvatar.color(for: "Example Service"))
        XCTAssertTrue(first == second)
    }

    func testColorDiffersForDifferentTitlesUsually() {
        let a = rgbaComponents(LetterAvatar.color(for: "Alpha"))
        let b = rgbaComponents(LetterAvatar.color(for: "Beta"))
        // Not guaranteed for every pair, but these hash to different palette slots.
        XCTAssertTrue(a != b)
    }

    private func rgbaComponents(_ color: Color) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        let ns = NSColor(color).usingColorSpace(.sRGB)!
        return (ns.redComponent, ns.greenComponent, ns.blueComponent, ns.alphaComponent)
    }
}
