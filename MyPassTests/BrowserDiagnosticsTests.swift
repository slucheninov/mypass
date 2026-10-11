import CryptoKit
import XCTest
import ExtensionBridgeKit
@testable import MyPass

final class BrowserDiagnosticsTests: XCTestCase {
    private func report(permission: BrowserDiagnosticsReport.PermissionState = .granted,
                        saving: Bool? = false,
                        scan: BrowserDiagnosticsReport.ExtensionScanState = .complete,
                        names: [String] = []) -> BrowserDiagnosticsReport {
        BrowserDiagnosticsReport(proxyState: .active, permissionState: permission,
                                 passwordSavingEnabled: saving, extensionScanState: scan, enabledManagers: names)
    }

    func testAuthenticatedLockedReportsBelongToActualPairingAndDoNotResetIdleTimer() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = VaultSession(fileStore: VaultFileStore(directory: folder))
        let pairings = InMemoryExtensionPairingStore()
        let manager = ExtensionPairingManager(store: pairings)
        let firstSecret = "first-test-secret"
        let secondSecret = "second-test-secret"
        let firstID = UUID()
        let secondID = UUID()
        for (id, secret) in [(firstID, firstSecret), (secondID, secondSecret)] {
            let hash = SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined()
            try pairings.add(PairedBrowser(id: id, label: "Chrome", createdAt: Date(), secretHash: hash))
        }
        let snapshots = BrowserDiagnosticsStore()
        let recorder = SpyAutoLockActivityRecorder()
        let receipt = Date(timeIntervalSince1970: 1234)
        let service = ExtensionBridgeService(vaultSession: session, pairingManager: manager,
                                            now: { receipt }, autoLockActivityRecorder: recorder,
                                            browserDiagnostics: snapshots)
        var settingsOpened = 0
        service.onBrowserSettingsRequested = { settingsOpened += 1 }
        XCTAssertEqual(service.handle(.openBrowserSettings(token: "t", pairing: nil)), .pairingRequired)
        XCTAssertEqual(service.handle(.openBrowserSettings(token: "t", pairing: firstSecret)), .acknowledged)
        XCTAssertEqual(settingsOpened, 1)
        XCTAssertEqual(service.handle(.reportBrowserDiagnostics(token: "t", report: report(names: ["1Password"]), pairing: firstSecret)), .acknowledged)
        XCTAssertEqual(service.handle(.reportBrowserDiagnostics(token: "t", report: report(saving: true), pairing: secondSecret)), .acknowledged)
        XCTAssertEqual(snapshots.snapshots[firstID]?.receivedAt, receipt)
        XCTAssertEqual(snapshots.snapshots[firstID]?.report.enabledManagers, ["1Password"])
        XCTAssertEqual(snapshots.snapshots[secondID]?.report.passwordSavingEnabled, true)
        XCTAssertEqual(service.handle(.reportBrowserDiagnostics(token: "t", report: report(), pairing: "wrong")), .pairingRequired)
        XCTAssertEqual(service.handle(.reportBrowserDiagnostics(token: "t", report: report(names: [String(repeating: "x", count: 121)]), pairing: firstSecret)), .error("invalid_browser_diagnostics"))
        XCTAssertEqual(snapshots.snapshots[firstID]?.report.enabledManagers, ["1Password"])
        try pairings.remove(id: firstID)
        snapshots.remove(browserID: firstID)
        XCTAssertEqual(service.handle(.reportBrowserDiagnostics(token: "t", report: report(), pairing: firstSecret)), .pairingRequired)
        XCTAssertEqual(service.handle(.openBrowserSettings(token: "t", pairing: firstSecret)), .pairingRequired)
        XCTAssertNil(snapshots.snapshots[firstID])
        XCTAssertEqual(settingsOpened, 1)
        XCTAssertEqual(recorder.recordActivityCallCount, 0)
    }

    func testPresentationDoesNotConfusePermissionDenialWithUnknownResults() {
        let denied = BrowserDiagnosticsSnapshot(report: report(permission: .notGranted, saving: nil, scan: .notChecked), receivedAt: Date())
        XCTAssertTrue(denied.managerStatus.contains("Check not allowed yet"))
        let unavailable = BrowserDiagnosticsSnapshot(report: report(permission: .unavailable, saving: nil, scan: .notChecked), receivedAt: Date())
        XCTAssertTrue(unavailable.managerStatus.contains("could not be read"))
        let failedScan = BrowserDiagnosticsSnapshot(report: report(saving: nil, scan: .unavailable), receivedAt: Date())
        XCTAssertTrue(failedScan.passwordSavingStatus.contains("unknown"))
        XCTAssertTrue(failedScan.managerStatus.contains("could not be checked"))
        let clean = BrowserDiagnosticsSnapshot(report: report(), receivedAt: Date())
        XCTAssertTrue(clean.managerStatus.contains("recognized"))
        XCTAssertTrue(clean.managerStatus.contains("last check"))
        XCTAssertFalse(clean.managerStatus.contains("all other"))
    }
}
