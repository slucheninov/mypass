import XCTest
@testable import MyPass

final class SettingsPaneTests: XCTestCase {
    func testPaneOrderIsGeneralVaultSecurityBrowserAppearanceAbout() {
        XCTAssertEqual(
            SettingsPane.allCases,
            [.general, .vault, .security, .browser, .appearance, .about]
        )
    }

    func testLegacyStoredValuesResolveToVault() {
        // Location, Sync and Backups used to be separate panes; their stored selections must land
        // on the merged Vault pane instead of falling back to General.
        for legacy in ["vaultLocation", "sync", "backups"] {
            XCTAssertEqual(SettingsPane.resolve(storedRaw: legacy), .vault, legacy)
        }
    }

    func testCurrentRawValuesResolveToThemselves() {
        for pane in SettingsPane.allCases {
            XCTAssertEqual(SettingsPane.resolve(storedRaw: pane.rawValue), pane)
        }
    }

    func testUnknownOrMissingStoredValuesResolveToGeneral() {
        for raw in [nil, "", "Vault", "nope"] as [String?] {
            XCTAssertEqual(SettingsPane.resolve(storedRaw: raw), .general, raw ?? "nil")
        }
    }

    func testEveryPaneHasATitleAndSymbol() {
        for pane in SettingsPane.allCases {
            XCTAssertFalse(String(localized: pane.title).isEmpty, pane.rawValue)
            XCTAssertFalse(pane.symbolName.isEmpty, pane.rawValue)
        }
    }

    func testStorageKeyIsStable() {
        XCTAssertEqual(SettingsPane.storageKey, "settingsSelectedPane")
    }
}
