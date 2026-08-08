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

    // MARK: - consumePendingProposals
    //
    // Covers the bug where a proposal arrives while the main window is closed:
    // NavigationState is mutated before ContentView (and its .onChange handlers)
    // exist, so .onChange never fires for the initial value and the proposal is
    // stranded. consumePendingProposals() is the window-independent fallback
    // called from onAppear (and reused by onChange) so the proposal is routed
    // regardless of subscription timing.

    func testConsumePendingProposals_totpWithEntryId_presentsEditAndClearsPending() {
        let state = NavigationState()
        let entryID = UUID()
        let proposal = PendingTotpSaveProposal(url: "https://example.com", otpauthOrSecret: "JBSWY3DP", entryId: entryID)
        state.pendingTotpSaveProposal = proposal

        state.consumePendingProposals()

        XCTAssertEqual(state.detailPresentation, .editFromTotpProposal(entryID: entryID, otpauthInput: "JBSWY3DP"))
        XCTAssertNil(state.pendingTotpSaveProposal)
    }

    func testConsumePendingProposals_totpWithoutEntryId_presentsCreateAndClearsPending() {
        let state = NavigationState()
        let proposal = PendingTotpSaveProposal(url: "https://example.com", otpauthOrSecret: "JBSWY3DP", entryId: nil)
        state.pendingTotpSaveProposal = proposal

        state.consumePendingProposals()

        XCTAssertEqual(state.detailPresentation, .createFromTotpProposal(proposal))
        XCTAssertNil(state.pendingTotpSaveProposal)
    }

    func testConsumePendingProposals_passwordProposal_presentsCreateAndClearsPending() {
        let state = NavigationState()
        let proposal = PendingSaveProposal(url: "https://example.com", username: "alice", password: "hunter2")
        state.pendingSaveProposal = proposal

        state.consumePendingProposals()

        XCTAssertEqual(state.detailPresentation, .createFromProposal(proposal))
        XCTAssertNil(state.pendingSaveProposal)
    }

    func testConsumePendingProposals_bothPending_totpWinsFinalPresentation() {
        let state = NavigationState()
        let entryID = UUID()
        let passwordProposal = PendingSaveProposal(url: "https://example.com", username: "alice", password: "hunter2")
        let totpProposal = PendingTotpSaveProposal(url: "https://example.com", otpauthOrSecret: "JBSWY3DP", entryId: entryID)
        state.pendingSaveProposal = passwordProposal
        state.pendingTotpSaveProposal = totpProposal

        state.consumePendingProposals()

        // Password proposal is consumed first, then TOTP — TOTP wins the final
        // detailPresentation since it is applied last. Both are cleared regardless.
        XCTAssertEqual(state.detailPresentation, .editFromTotpProposal(entryID: entryID, otpauthInput: "JBSWY3DP"))
        XCTAssertNil(state.pendingSaveProposal)
        XCTAssertNil(state.pendingTotpSaveProposal)
    }

    func testConsumePendingProposals_nothingPending_leavesDetailPresentationUntouched() {
        let state = NavigationState()
        state.detailPresentation = .edit(entryID: UUID())
        let expected = state.detailPresentation

        state.consumePendingProposals()

        XCTAssertEqual(state.detailPresentation, expected)
        XCTAssertNil(state.pendingSaveProposal)
        XCTAssertNil(state.pendingTotpSaveProposal)
    }
}
