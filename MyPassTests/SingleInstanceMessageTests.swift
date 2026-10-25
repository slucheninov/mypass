import XCTest
@testable import MyPass

final class SingleInstanceMessageTests: XCTestCase {
    private let a = ProcessIdentity(pid: 4242, startMicroseconds: 1_792_000_000_123_456)
    private let b = ProcessIdentity(pid: 77, startMicroseconds: 1_792_000_009_000_001)

    private var everyShape: [SingleInstanceMessage] {
        [
            .probe(from: a, attempt: 18_446_744_073_709_551_615),
            .ready(from: a, to: b, attempt: 5, role: .owner),
            .ready(from: a, to: b, attempt: 5, role: .launcher),
            .ready(from: a, to: b, attempt: 5, role: .inactive),
            .commit(from: a, attempt: 5, deadlineMillis: 123_456_789),
            .ack(from: a, to: b, attempt: 5),
            .refuse(from: a, to: b, attempt: 5),
            .withdraw(from: a, attempt: 5),
        ]
    }

    func testWireFormatsAreExactlyTheDocumentedOnes() {
        XCTAssertEqual(SingleInstanceMessage.probe(from: a, attempt: 9).wire, "v2 probe 4242 1792000000123456 9")
        XCTAssertEqual(SingleInstanceMessage.ready(from: a, to: b, attempt: 9, role: .inactive).wire,
                       "v2 ready 4242 1792000000123456 77 1792000009000001 9 inactive")
        XCTAssertEqual(SingleInstanceMessage.commit(from: a, attempt: 9, deadlineMillis: 5000).wire, "v2 commit 4242 1792000000123456 9 5000")
        XCTAssertEqual(SingleInstanceMessage.ack(from: a, to: b, attempt: 9).wire, "v2 ack 4242 1792000000123456 77 1792000009000001 9")
        XCTAssertEqual(SingleInstanceMessage.refuse(from: a, to: b, attempt: 9).wire, "v2 refuse 4242 1792000000123456 77 1792000009000001 9")
        XCTAssertEqual(SingleInstanceMessage.withdraw(from: a, attempt: 9).wire, "v2 withdraw 4242 1792000000123456 9")
    }

    func testEveryMessageRoundTripsWithinTheLengthBound() {
        for message in everyShape {
            XCTAssertEqual(SingleInstanceMessage(wire: message.wire), message, message.wire)
            XCTAssertLessThanOrEqual(message.wire.utf8.count, 160)
        }
    }

    func testMalformedPayloadsAreRejected() {
        let rejected = [
            "", "garbage", "v1 takeover 1 2", "v1 probe 1 2 3", "v3 probe 1 2 3", "V2 probe 1 2 3",
            "v2 probe 1 2", "v2 probe 1 2 3 4", "v2 probe -1 2 3", "v2 probe 1 -2 3", "v2 probe +1 2 3", "v2 probe 0 2 3", "v2 probe 1 0 3",
            "v2 probe 1.5 2 3", "v2 probe 99999999999 2 3", "v2 probe  1 2 3", "v2 probe 1 2 3 ", "v2 probe 1 2 x", "v2 probe 1 2 -3",
            "v2 probe 1 2 18446744073709551616",
            "v2 commit 1 2 3", "v2 commit 1 2 3 x", "v2 commit 1 2 3 4 5", "v2 commit 1 2 3 -4",
            "v2 ack 1 2 3 4", "v2 ack 1 2 3 4 5 6", "v2 ack 1 2 3 x 5", "v2 refuse 1 2 3 4", "v2 withdraw 1 2", "v2 withdraw 1 2 3 4",
            "v2 ready 1 2 3 4 5", "v2 ready 1 2 3 4 5 boss", "v2 ready 1 2 3 4 5 OWNER", "v2 ready 1 2 3 4 5 owner extra",
            "v2 unknown 1 2 3", "v2 probe 1 2 3\n", "v2 probe \u{0661} 2 3",
            String(repeating: "9", count: 400),
            "v2 probe 1 2 " + String(repeating: "9", count: 200),
        ]
        for payload in rejected {
            XCTAssertNil(SingleInstanceMessage(wire: payload), "should reject \(payload.debugDescription)")
        }
    }

    func testPayloadCarriesOnlyIdentitiesAttemptsAndADeadline() {
        // No path, no token, no credential: process ids, start times, numbers and a role word.
        for message in everyShape {
            XCTAssertTrue(message.wire.allSatisfy { $0.isASCII && ($0.isNumber || $0 == " " || $0.isLetter) }, message.wire)
            XCTAssertFalse(message.wire.contains("/"))
        }
    }

    func testNewerIsGreaterByStartTimeThenPid() {
        let older = ProcessIdentity(pid: 900, startMicroseconds: 10)
        let newer = ProcessIdentity(pid: 1, startMicroseconds: 11)
        XCTAssertTrue(older < newer)
        XCTAssertTrue(ProcessIdentity(pid: 5, startMicroseconds: 10) < ProcessIdentity(pid: 6, startMicroseconds: 10))
    }
}
