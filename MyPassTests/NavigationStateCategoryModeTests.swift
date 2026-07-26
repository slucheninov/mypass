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
}
