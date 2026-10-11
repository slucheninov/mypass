import XCTest
@testable import MyPass

final class NavigationStateCategoryModeTests: XCTestCase {
    func testSelectSmartCategoryEntersCategoryMode() {
        let state = NavigationState()
        state.selectSmartCategory(.codes)
        XCTAssertTrue(state.isCategoryMode)
        XCTAssertEqual(state.selectedSmartCategory, .codes)
        XCTAssertEqual(state.activeCategoryFilter, .codes)
    }

    func testSelectSecurityDoesNotChangeActiveCategoryFilter() {
        let state = NavigationState()
        state.selectSmartCategory(.all)
        state.selectSmartCategory(.security)
        XCTAssertEqual(state.selectedSmartCategory, .security)
        XCTAssertEqual(state.activeCategoryFilter, .all)
    }

    func testGroupSelectionExitsCategoryMode() {
        let state = NavigationState()
        state.selectSmartCategory(.deleted)
        state.exitCategoryModeForGroupSelection()
        XCTAssertFalse(state.isCategoryMode)
        XCTAssertEqual(state.selectedSmartCategory, .all)
        XCTAssertEqual(state.activeCategoryFilter, .all)
    }

    func testReSelectingSecurityPreservesGroupScope() {
        let state = NavigationState()
        state.selectSmartCategory(.security)
        XCTAssertTrue(state.securityUsesGroupScope)
        XCTAssertEqual(state.activeCategoryFilter, .all)

        state.selectSmartCategory(.security)
        XCTAssertTrue(state.securityUsesGroupScope)
        XCTAssertEqual(state.activeCategoryFilter, .all)
        XCTAssertEqual(state.selectedSmartCategory, .security)
    }

    func testSidebarGroupSelectionClearsWhileCategoryModeActive() {
        let state = NavigationState()
        let groupID = UUID()
        state.selectedGroupID = groupID
        XCTAssertEqual(state.sidebarSelectedGroupID, groupID)

        state.selectSmartCategory(.codes)
        XCTAssertNil(state.sidebarSelectedGroupID, "Group must not appear selected once a category is active")
        XCTAssertEqual(state.selectedGroupID, groupID, "Underlying group selection is preserved for group-scoped features")
    }

    func testNoSmartCategoryAppearsSelectedWhileGroupModeActive() {
        let state = NavigationState()
        state.selectSmartCategory(.codes)
        XCTAssertTrue(state.isSmartCategorySelected(.codes))

        state.exitCategoryModeForGroupSelection()
        XCTAssertFalse(state.isSmartCategorySelected(.codes))
        XCTAssertFalse(state.isSmartCategorySelected(.all), "No category should read as selected once a specific group is active")
    }
    func testChangingCategoryClearsBrowseSelectionButReselectingSameCategoryKeepsIt() {
        let state = NavigationState()
        state.selectedEntryID = UUID()
        state.selectSmartCategory(.addresses)
        XCTAssertNil(state.selectedEntryID)
        let selected = UUID()
        state.selectedEntryID = selected
        state.selectSmartCategory(.addresses)
        XCTAssertEqual(state.selectedEntryID, selected)
        state.selectSmartCategory(.passkeys)
        XCTAssertNil(state.selectedEntryID)
    }

    func testReturningToRememberedGroupExitsCategoryModeAndClearsStaleEntry() {
        let state = NavigationState()
        let groupID = UUID()
        state.selectedGroupID = groupID
        state.selectSmartCategory(.codes)
        state.selectedEntryID = UUID()
        state.sidebarSelectedGroupID = nil
        XCTAssertEqual(state.selectedGroupID, groupID)
        XCTAssertTrue(state.isCategoryMode)
        state.sidebarSelectedGroupID = groupID
        XCTAssertFalse(state.isCategoryMode)
        XCTAssertEqual(state.sidebarSelectedGroupID, groupID)
        XCTAssertNil(state.selectedEntryID)
    }

    func testChangingGroupClearsBrowseSelectionButReselectingSameGroupKeepsIt() {
        let state = NavigationState()
        state.sidebarSelectedGroupID = UUID()
        let selected = UUID()
        state.selectedEntryID = selected
        state.sidebarSelectedGroupID = state.selectedGroupID
        XCTAssertEqual(state.selectedEntryID, selected)
        state.sidebarSelectedGroupID = UUID()
        XCTAssertNil(state.selectedEntryID)
    }

    func testScopeChangesDoNotDiscardEditorsOrIncomingProposals() {
        let entryID = UUID()
        let presentations: [DetailPresentation] = [
            .edit(entryID: entryID), .create(defaultGroupID: nil, entryType: .address),
            .createFromProposal(PendingSaveProposal(url: "https://example.com", username: "person", password: "fixture")),
            .createFromTotpProposal(PendingTotpSaveProposal(url: "https://example.com", otpauthOrSecret: "fixture", entryId: nil)),
            .editFromTotpProposal(entryID: entryID, otpauthInput: "fixture")
        ]
        for presentation in presentations {
            let state = NavigationState()
            state.selectedEntryID = entryID
            state.detailPresentation = presentation
            state.selectSmartCategory(.cards)
            XCTAssertEqual(state.selectedEntryID, entryID)
            XCTAssertEqual(state.detailPresentation, presentation)
            state.sidebarSelectedGroupID = UUID()
            XCTAssertEqual(state.selectedEntryID, entryID)
            XCTAssertEqual(state.detailPresentation, presentation)
        }
    }

}
