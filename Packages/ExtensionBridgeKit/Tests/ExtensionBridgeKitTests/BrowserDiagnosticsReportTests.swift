import XCTest
@testable import ExtensionBridgeKit

final class BrowserDiagnosticsReportTests: XCTestCase {
    private let report = BrowserDiagnosticsReport(proxyState: .active, permissionState: .granted,
                                                  passwordSavingEnabled: nil, extensionScanState: .complete,
                                                  enabledManagers: ["1Password", "iCloud Passwords"])

    func testRequestsRoundTripAndAreLockedSafeWithoutActivityReset() throws {
        for request in [ExtensionBridgeRequest.openBrowserSettings(token: "t", pairing: "p"),
                        .reportBrowserDiagnostics(token: "t", report: report, pairing: "p")] {
            let data = try JSONEncoder().encode(request)
            XCTAssertEqual(try JSONDecoder().decode(ExtensionBridgeRequest.self, from: data), request)
            XCTAssertTrue(request.isAnswerableWhileLocked)
            XCTAssertFalse(request.resetsAutoLockTimer)
        }
    }

    func testMalformedEnumsFailDecoding() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        for key in ["proxyState", "permissionState", "extensionScanState"] {
            var invalid = object
            invalid[key] = "invented"
            XCTAssertThrowsError(try JSONDecoder().decode(BrowserDiagnosticsReport.self, from: JSONSerialization.data(withJSONObject: invalid)))
        }
        object["passwordSavingEnabled"] = NSNull()
        XCTAssertTrue(try JSONDecoder().decode(BrowserDiagnosticsReport.self, from: JSONSerialization.data(withJSONObject: object)).isValid)
    }

    func testReportBoundsAndConsistentUnknownStates() {
        func valid(_ names: [String], permission: BrowserDiagnosticsReport.PermissionState = .granted,
                   scan: BrowserDiagnosticsReport.ExtensionScanState = .complete, saving: Bool? = nil) -> Bool {
            BrowserDiagnosticsReport(proxyState: .active, permissionState: permission, passwordSavingEnabled: saving,
                                     extensionScanState: scan, enabledManagers: names).isValid
        }
        XCTAssertTrue(report.isValid)
        XCTAssertFalse(valid(Array(repeating: "Manager", count: 21)))
        XCTAssertFalse(valid([String(repeating: "x", count: 121)]))
        XCTAssertFalse(valid(["Manager\nInjected"]))
        XCTAssertFalse(valid([" "]))
        XCTAssertFalse(valid(["1Password"], scan: .unavailable))
        XCTAssertFalse(valid([], permission: .notGranted, scan: .notChecked, saving: true))
        XCTAssertTrue(valid([], permission: .notGranted, scan: .notChecked))
        XCTAssertTrue(valid([], permission: .unavailable, scan: .notChecked))
    }
}
