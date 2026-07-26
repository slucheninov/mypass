import XCTest
@testable import MyPass

final class NavigationStatePendingSaveProposalTests: XCTestCase {
    func testRegistrableDomainUsesParsedDomainForValidURL() {
        let proposal = PendingSaveProposal(url: "https://login.example.com/signup", username: "alice", password: "pw")
        XCTAssertEqual(proposal.registrableDomain, "example.com")
    }

    func testRegistrableDomainFallsBackToRawURLWhenUnparseable() {
        let proposal = PendingSaveProposal(url: "not a url $$$", username: "alice", password: "pw")
        XCTAssertEqual(proposal.registrableDomain, "not a url $$$")
    }
}
