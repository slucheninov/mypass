import ExtensionBridgeKit
import XCTest
@testable import MyPass

final class ExtensionPairingManagerTests: XCTestCase {
    private var store: InMemoryExtensionPairingStore!
    private var now: Date!
    private var manager: ExtensionPairingManager!

    override func setUp() {
        store = InMemoryExtensionPairingStore()
        now = Date(timeIntervalSinceReferenceDate: 100_000)
        manager = ExtensionPairingManager(store: store, now: { [unowned self] in self.now })
    }

    func testStartPairingProducesSixDigitCode() {
        let code = manager.startPairing(browser: nil)
        XCTAssertEqual(code.count, 6)
        XCTAssertTrue(code.allSatisfy(\.isNumber))
    }

    func testCompletePairingSucceedsWithMatchingCode() throws {
        let code = manager.startPairing(browser: nil)
        let secret = try XCTUnwrap(manager.completePairing(code: code))
        XCTAssertFalse(secret.isEmpty)
        XCTAssertTrue(manager.isAuthorized(pairing: secret))
    }

    func testCompletePairingSucceedsWhenCodeContainsInternalSpace() throws {
        let code = manager.startPairing(browser: nil)
        var spacedCode = Array(code)
        spacedCode.insert(" ", at: 3)
        let secret = try XCTUnwrap(manager.completePairing(code: String(spacedCode)))
        XCTAssertFalse(secret.isEmpty)
        XCTAssertTrue(manager.isAuthorized(pairing: secret))
    }

    func testCompletePairingUsesBrowserLabelFromStartPairing() throws {
        let code = manager.startPairing(browser: "Microsoft Edge")
        _ = try XCTUnwrap(manager.completePairing(code: code))
        XCTAssertEqual(store.list().map(\.label), ["Microsoft Edge"])
    }

    func testCompletePairingUsesFallbackLabelWhenBrowserNil() throws {
        let code = manager.startPairing(browser: nil)
        _ = try XCTUnwrap(manager.completePairing(code: code))
        XCTAssertEqual(store.list().map(\.label), ["Chromium browser"])
    }

    func testCompletePairingFailsAfterTTL() {
        let code = manager.startPairing(browser: nil)
        now = now.addingTimeInterval(121)
        XCTAssertNil(manager.completePairing(code: code))
    }

    func testCompletePairingLocksOutAfterFiveFailedAttempts() {
        let code = manager.startPairing(browser: nil)
        for _ in 0..<4 { XCTAssertNil(manager.completePairing(code: "000000")) }
        XCTAssertNil(manager.completePairing(code: code), "correct code must fail after 5 attempts")
    }

    func testCancelPairingClearsActiveChallenge() {
        let code = manager.startPairing(browser: nil)
        manager.cancelPairing()
        XCTAssertNil(manager.completePairing(code: code))
    }

    func testIsAuthorizedReturnsFalseForNilOrUnknown() {
        XCTAssertFalse(manager.isAuthorized(pairing: nil))
        XCTAssertFalse(manager.isAuthorized(pairing: "unknown"))
    }

    func testCompletePairingReturnsNilWhenStorePersistenceFails() {
        let throwingStore = ThrowingExtensionPairingStore()
        let manager = ExtensionPairingManager(store: throwingStore, now: { [unowned self] in self.now })
        var pairingFinished = false
        manager.onPairingFinished = { pairingFinished = true }

        let code = manager.startPairing(browser: nil)
        XCTAssertNil(manager.completePairing(code: code))
        XCTAssertTrue(throwingStore.list().isEmpty)
        XCTAssertTrue(pairingFinished)
        XCTAssertFalse(manager.isAuthorized(pairing: ExtensionBridgeTokenStore.generateToken()))
    }
}

private final class ThrowingExtensionPairingStore: ExtensionPairingStoring {
    func list() -> [PairedBrowser] { [] }

    func add(_ browser: PairedBrowser) throws {
        throw ExtensionPairingStoreError.encodingFailed
    }

    func remove(id: UUID) throws {}

    func containsSecret(matching secret: String) -> Bool { false }
}
