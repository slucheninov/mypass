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
}
