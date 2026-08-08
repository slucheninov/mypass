import XCTest
@testable import MyPass

final class NavigationStatePendingTotpSaveProposalTests: XCTestCase {
    func testRegistrableDomainParsesHostFromURL() {
        let proposal = PendingTotpSaveProposal(url: "https://accounts.example.com/2fa/setup", otpauthOrSecret: "JBSWY3DP", entryId: nil)
        XCTAssertEqual(proposal.registrableDomain, "example.com")
    }

    func testRegistrableDomainFallsBackToRawURLWhenUnparsable() {
        let proposal = PendingTotpSaveProposal(url: "not-a-url", otpauthOrSecret: "JBSWY3DP", entryId: nil)
        XCTAssertEqual(proposal.registrableDomain, "not-a-url")
    }
}
