import XCTest
@testable import MyPass

final class SettingsWindowPlacementTests: XCTestCase {
    private let screenA = SettingsWindowPlacement.Screen(
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875)
    )
    private let screenB = SettingsWindowPlacement.Screen(
        frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1055)
    )
    private let settingsSize = CGSize(width: 660, height: 420)

    private func mid(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }

    func testCentersOverAnchorOnItsScreen() throws {
        let anchor = CGRect(x: 1600, y: 200, width: 800, height: 600)
        let frame = try XCTUnwrap(SettingsWindowPlacement.targetFrame(
            windowSize: settingsSize, anchor: anchor,
            pointer: CGPoint(x: 100, y: 100), screens: [screenA, screenB]))
        XCTAssertEqual(mid(frame), mid(anchor))
        XCTAssertEqual(frame.size, settingsSize)
    }

    func testWithoutAnchorCentersOnScreenUnderPointer() throws {
        let frame = try XCTUnwrap(SettingsWindowPlacement.targetFrame(
            windowSize: settingsSize, anchor: nil,
            pointer: CGPoint(x: 2000, y: 500), screens: [screenA, screenB]))
        XCTAssertEqual(mid(frame), mid(screenB.visibleFrame))
    }

    func testClampsInsideVisibleFrameWhenAnchorIsNearAnEdge() throws {
        // The anchor hangs off the right edge of B, so its midpoint would push the window out.
        let anchor = CGRect(x: 3000, y: 200, width: 800, height: 600)
        let frame = try XCTUnwrap(SettingsWindowPlacement.targetFrame(
            windowSize: settingsSize, anchor: anchor,
            pointer: CGPoint(x: 100, y: 100), screens: [screenA, screenB]))
        XCTAssertLessThanOrEqual(frame.maxX, 3360)
        XCTAssertTrue(screenB.visibleFrame.contains(frame))
    }

    func testPicksScreenWithLargestOverlapWhenAnchorSpansTwoScreens() throws {
        // x 1300...1700: 140 pt on A, 260 pt on B.
        let anchor = CGRect(x: 1300, y: 100, width: 400, height: 300)
        let frame = try XCTUnwrap(SettingsWindowPlacement.targetFrame(
            windowSize: settingsSize, anchor: anchor,
            pointer: CGPoint(x: 100, y: 100), screens: [screenA, screenB]))
        XCTAssertTrue(screenB.visibleFrame.contains(frame))
    }

    func testOversizedWindowPinsToTopLeftOfVisibleFrame() throws {
        let frame = try XCTUnwrap(SettingsWindowPlacement.targetFrame(
            windowSize: CGSize(width: 2000, height: 1200), anchor: nil,
            pointer: CGPoint(x: 100, y: 100), screens: [screenA, screenB]))
        XCTAssertEqual(frame.origin.x, 0)
        XCTAssertEqual(frame.maxY, 875)
        XCTAssertEqual(frame.size, CGSize(width: 2000, height: 1200))
    }

    func testNoScreensReturnsNil() {
        XCTAssertNil(SettingsWindowPlacement.targetFrame(
            windowSize: settingsSize, anchor: nil, pointer: .zero, screens: []))
    }

    func testPointerOutsideAllScreensFallsBackToFirstScreen() throws {
        let frame = try XCTUnwrap(SettingsWindowPlacement.targetFrame(
            windowSize: settingsSize, anchor: nil,
            pointer: CGPoint(x: -5000, y: -5000), screens: [screenA, screenB]))
        XCTAssertEqual(mid(frame), mid(screenA.visibleFrame))
    }

    func testEqualOverlapPicksTheFirstScreen() throws {
        // Two side-by-side screens of equal size; the anchor straddles the seam evenly.
        let left = SettingsWindowPlacement.Screen(
            frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let right = SettingsWindowPlacement.Screen(
            frame: CGRect(x: 1000, y: 0, width: 1000, height: 800),
            visibleFrame: CGRect(x: 1000, y: 0, width: 1000, height: 800))
        let anchor = CGRect(x: 900, y: 100, width: 200, height: 200)
        for screens in [[left, right], [right, left]] {
            let frame = try XCTUnwrap(SettingsWindowPlacement.targetFrame(
                windowSize: settingsSize, anchor: anchor,
                pointer: CGPoint(x: 100, y: 100), screens: screens))
            XCTAssertTrue(screens[0].visibleFrame.contains(frame))
        }
    }

    func testAnchorTouchingNoScreenFallsBackToPointerScreen() throws {
        let anchor = CGRect(x: -5000, y: -5000, width: 400, height: 300)
        let frame = try XCTUnwrap(SettingsWindowPlacement.targetFrame(
            windowSize: settingsSize, anchor: anchor,
            pointer: CGPoint(x: 2000, y: 500), screens: [screenA, screenB]))
        XCTAssertTrue(screenB.visibleFrame.contains(frame))
    }
}
