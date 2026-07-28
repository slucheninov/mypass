import XCTest
@testable import MyPass

final class TOTPCountdownRingViewTests: XCTestCase {
    func testProgressIsFullAtStartOfPeriod() {
        let periodStart = Date(timeIntervalSince1970: 1_700_000_010) // divisible by 30
        let progress = TOTPCountdownRingView.progress(period: 30, now: periodStart)
        XCTAssertEqual(progress, 1.0, accuracy: 0.001)
    }

    func testProgressIsHalfAtMidpoint() {
        let midpoint = Date(timeIntervalSince1970: 1_700_000_025) // 15s into a 30s period starting at 1_700_000_010
        let progress = TOTPCountdownRingView.progress(period: 30, now: midpoint)
        XCTAssertEqual(progress, 0.5, accuracy: 0.001)
    }

    func testProgressStaysWithinZeroToOne() {
        for offset in stride(from: 0.0, to: 30.0, by: 3.0) {
            let now = Date(timeIntervalSince1970: 1_700_000_000 + offset)
            let progress = TOTPCountdownRingView.progress(period: 30, now: now)
            XCTAssertGreaterThanOrEqual(progress, 0.0)
            XCTAssertLessThanOrEqual(progress, 1.0)
        }
    }
}
