# Unlock & Auto-lock Settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace MyPass's Auto-Lock + Touch ID Security settings with a Bitwarden-style Unlock section (Touch ID / Mac password toggles with re-auth timers) and a redesigned Auto-lock section, fixing a latent Keychain-staleness bug as a side effect.

**Architecture:** A single Keychain item stores the actual master password (not a derived key), protected by a `SecAccessControl` chosen from two independent toggles (Touch ID, Mac password). Two non-secret `@AppStorage` timestamps gate how long device-based unlock stays trusted before falling back to the real master password. `UnlockView` and `SecuritySettingsPane` are rewritten to use this; the existing derived-key `VaultBiometricEnrollment` mechanism (which goes stale on every vault save) is deleted outright, not run in parallel.

**Tech Stack:** Swift, SwiftUI, XCTest, macOS Keychain Services (`Security` framework), `LocalAuthentication` (implicit, ACL-driven — no direct `LAContext.evaluatePolicy` calls, matching the codebase's existing pattern).

## Global Constraints

- Never store the master password or any derived key in `@AppStorage` — only in the Keychain behind a `SecAccessControl`, or in-memory (`VaultSession.sessionPassword`). Only non-secret booleans/enums/timestamps go in `@AppStorage`.
- No standalone "Change master password" or "Remove master password" UI — out of scope per the approved design spec (`docs/superpowers/specs/2026-07-28-unlock-autolock-settings-design.md`).
- Follow existing SwiftUI conventions exactly: `Form { Section { ... } header: { Text(...) } }`, `.formStyle(.grouped).padding()`, `SettingsHelperText(text:)` rows, inline red `.caption` error `Text`, sheet-based confirmation matching the existing Touch ID confirm sheet's structure (`VStack(spacing: 16)`, `.padding(24).frame(width: 360)`, `SecureField` + Cancel/primary `HStack` footer with `.keyboardShortcut(.defaultAction)`).
- New `@AppStorage` keys must not collide with existing keys: `settingsSelectedPane`, `syncBackend`, `syncLocalFolderBookmark`, `SyncBackendResolver.iCloudFolderBookmarkKey`, `syncSFTPHost`, `syncSFTPPort`, `syncSFTPUsername`, `syncSFTPRemotePath`, `syncSFTPPrivateKeyPath`, `syncSFTPCertificatePath`, `autoLockTimeoutMinutes`, `clipboardClearSeconds`, `showMenuBarExtra`, `menuBarClickAction`, `launchAtLogin`, `backupCount`, `shortcutShowMyPass`, `shortcutLockMyPass`. This plan deliberately does **not** reuse `autoLockTimeoutMinutes` for the new idle-timeout picker (it changes from a raw `Double` to a `String`-backed enum; reusing the key would silently reset under a type mismatch) — it introduces `autoLockIdleTimeout` instead, matching the design spec's intent ("same underlying setting, reused controller") at the `AutoLockController` level even though the `@AppStorage` key itself is new.
- Match the existing repo idiom of duplicating `@AppStorage` key string literals verbatim across the views that need them (see `showMenuBarExtra` duplicated in `GeneralSettingsPane.swift` and `MyPassApp.swift`) rather than introducing a shared constants file — do not add a `UnlockPreferenceKeys`-style abstraction.
- Real Keychain I/O (`SecItemAdd`/`SecItemCopyMatching` via the concrete `BiometricKeyStore` class) and real `LAContext` biometric prompts must never run in the automated test suite — every test in this plan uses `FakeBiometricKeyStore`. The one exception is `SecAccessControlCreateWithFlags`, which is pure in-memory object construction (no Keychain I/O) and is safe to call directly in tests.
- Test command for the `MyPass`/`MyPassTests` target: `./scripts/generate.sh && xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS'` (run from repo root `/Users/lucheninov/Documents/Works/all_sync_docs/mypass`). `./scripts/test.sh` runs this plus the Swift package test suites.

---

### Task 1: `DeviceUnlockAccessControl` + configurable-ACL `BiometricKeyStoring`

**Files:**
- Create: `MyPass/Security/DeviceUnlockAccessControl.swift`
- Modify: `MyPass/Security/BiometricKeyStore.swift` (full current content below)
- Test: `MyPassTests/DeviceUnlockAccessControlTests.swift`

**Interfaces:**
- Produces: `enum DeviceUnlockAccessControl: Equatable { case touchID, devicePassword, touchIDOrDevicePassword }` with `var secAccessControlFlags: SecAccessControlCreateFlags` and `static func forToggles(touchIDEnabled: Bool, macPasswordEnabled: Bool) -> DeviceUnlockAccessControl?` (nil means "remove enrollment entirely").
- Produces: `protocol BiometricKeyStoring { func store(derivedKey: Data, account: String, accessControl: DeviceUnlockAccessControl) throws; func retrieve(account: String) throws -> Data?; func remove(account: String) throws; func hasStoredKey(account: String) throws -> Bool }` — the `store` signature gains the `accessControl:` parameter (breaking change from the current 2-arg form).
- Produces: `FakeBiometricKeyStore.accessControls: [String: DeviceUnlockAccessControl]` (read-only from outside via direct property access, populated by `store`) so later tests can assert which ACL was requested.

The current full content of `MyPass/Security/BiometricKeyStore.swift` (123 lines) is:

```swift
import Foundation
import Security
import LocalAuthentication

protocol BiometricKeyStoring {
    func store(derivedKey: Data, account: String) throws
    func retrieve(account: String) throws -> Data?
    func remove(account: String) throws
    func hasStoredKey(account: String) throws -> Bool
}

enum BiometricKeyStoreError: Error {
    case accessControlCreationFailed
    case keychainWrite(OSStatus)
    case keychainRead(OSStatus)
}

final class BiometricKeyStore: BiometricKeyStoring {
    private let service: String

    init(service: String = "com.mypass.app.biometric") {
        self.service = service
    }

    func store(derivedKey: Data, account: String) throws {
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .biometryCurrentSet,
            nil
        ) else {
            throw BiometricKeyStoreError.accessControlCreationFailed
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = derivedKey
        attributes[kSecAttrAccessControl as String] = accessControl

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw BiometricKeyStoreError.keychainWrite(status)
        }
    }

    func retrieve(account: String) throws -> Data? {
        let context = LAContext()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: context
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw BiometricKeyStoreError.keychainRead(status)
        }
        return result as? Data
    }

    func remove(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw BiometricKeyStoreError.keychainWrite(status)
        }
    }

    func hasStoredKey(account: String) throws -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return false
        }
        guard status == errSecSuccess else {
            throw BiometricKeyStoreError.keychainRead(status)
        }
        return true
    }
}

final class FakeBiometricKeyStore: BiometricKeyStoring {
    private var storage: [String: Data] = [:]

    func store(derivedKey: Data, account: String) throws {
        storage[account] = derivedKey
    }

    func retrieve(account: String) throws -> Data? {
        storage[account]
    }

    func remove(account: String) throws {
        storage.removeValue(forKey: account)
    }

    func hasStoredKey(account: String) throws -> Bool {
        storage[account] != nil
    }
}
```

- [ ] **Step 1: Write the failing test**

Create `MyPassTests/DeviceUnlockAccessControlTests.swift`:

```swift
import XCTest
import Security
@testable import MyPass

final class DeviceUnlockAccessControlTests: XCTestCase {
    func testForTogglesMapsCombinationsCorrectly() {
        XCTAssertEqual(
            DeviceUnlockAccessControl.forToggles(touchIDEnabled: true, macPasswordEnabled: false),
            .touchID
        )
        XCTAssertEqual(
            DeviceUnlockAccessControl.forToggles(touchIDEnabled: false, macPasswordEnabled: true),
            .devicePassword
        )
        XCTAssertEqual(
            DeviceUnlockAccessControl.forToggles(touchIDEnabled: true, macPasswordEnabled: true),
            .touchIDOrDevicePassword
        )
        XCTAssertNil(
            DeviceUnlockAccessControl.forToggles(touchIDEnabled: false, macPasswordEnabled: false)
        )
    }

    func testEachAccessControlProducesAValidSecAccessControl() {
        for accessControl in [DeviceUnlockAccessControl.touchID, .devicePassword, .touchIDOrDevicePassword] {
            let secAccessControl = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                accessControl.secAccessControlFlags,
                nil
            )
            XCTAssertNotNil(secAccessControl, "Expected a valid SecAccessControl for \(accessControl)")
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/generate.sh && xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/DeviceUnlockAccessControlTests`
Expected: FAIL to build — `DeviceUnlockAccessControl` does not exist yet.

- [ ] **Step 3: Create `DeviceUnlockAccessControl` and update `BiometricKeyStoring`**

Create `MyPass/Security/DeviceUnlockAccessControl.swift`:

```swift
import Security

enum DeviceUnlockAccessControl: Equatable {
    case touchID
    case devicePassword
    case touchIDOrDevicePassword

    var secAccessControlFlags: SecAccessControlCreateFlags {
        switch self {
        case .touchID: return .biometryCurrentSet
        case .devicePassword: return .devicePasscode
        case .touchIDOrDevicePassword: return .userPresence
        }
    }

    static func forToggles(touchIDEnabled: Bool, macPasswordEnabled: Bool) -> DeviceUnlockAccessControl? {
        switch (touchIDEnabled, macPasswordEnabled) {
        case (true, true): return .touchIDOrDevicePassword
        case (true, false): return .touchID
        case (false, true): return .devicePassword
        case (false, false): return nil
        }
    }
}
```

Replace the full content of `MyPass/Security/BiometricKeyStore.swift` with:

```swift
import Foundation
import Security
import LocalAuthentication

protocol BiometricKeyStoring {
    func store(derivedKey: Data, account: String, accessControl: DeviceUnlockAccessControl) throws
    func retrieve(account: String) throws -> Data?
    func remove(account: String) throws
    func hasStoredKey(account: String) throws -> Bool
}

enum BiometricKeyStoreError: Error {
    case accessControlCreationFailed
    case keychainWrite(OSStatus)
    case keychainRead(OSStatus)
}

final class BiometricKeyStore: BiometricKeyStoring {
    private let service: String

    init(service: String = "com.mypass.app.biometric") {
        self.service = service
    }

    func store(derivedKey: Data, account: String, accessControl: DeviceUnlockAccessControl) throws {
        guard let secAccessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            accessControl.secAccessControlFlags,
            nil
        ) else {
            throw BiometricKeyStoreError.accessControlCreationFailed
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = derivedKey
        attributes[kSecAttrAccessControl as String] = secAccessControl

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw BiometricKeyStoreError.keychainWrite(status)
        }
    }

    func retrieve(account: String) throws -> Data? {
        let context = LAContext()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: context
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw BiometricKeyStoreError.keychainRead(status)
        }
        return result as? Data
    }

    func remove(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw BiometricKeyStoreError.keychainWrite(status)
        }
    }

    func hasStoredKey(account: String) throws -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return false
        }
        guard status == errSecSuccess else {
            throw BiometricKeyStoreError.keychainRead(status)
        }
        return true
    }
}

final class FakeBiometricKeyStore: BiometricKeyStoring {
    private var storage: [String: Data] = [:]
    var accessControls: [String: DeviceUnlockAccessControl] = [:]

    func store(derivedKey: Data, account: String, accessControl: DeviceUnlockAccessControl) throws {
        storage[account] = derivedKey
        accessControls[account] = accessControl
    }

    func retrieve(account: String) throws -> Data? {
        storage[account]
    }

    func remove(account: String) throws {
        storage.removeValue(forKey: account)
        accessControls.removeValue(forKey: account)
    }

    func hasStoredKey(account: String) throws -> Bool {
        storage[account] != nil
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/generate.sh && xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/DeviceUnlockAccessControlTests`
Expected: PASS. Note: the full `MyPassTests` target and `MyPass` app target will NOT build yet at this point, because `VaultBiometricEnrollment.swift` (Task 4) and `SecuritySettingsPane.swift`/`UnlockView.swift` (Tasks 5-6) still call the old 2-arg `store(derivedKey:account:)`. This is expected and resolved by Task 4; running the full suite before then will fail to build. Only run the scoped `-only-testing:MyPassTests/DeviceUnlockAccessControlTests` target for this task's verification.

- [ ] **Step 5: Commit**

```bash
git add MyPass/Security/DeviceUnlockAccessControl.swift MyPass/Security/BiometricKeyStore.swift MyPassTests/DeviceUnlockAccessControlTests.swift
git commit -m "feat: add configurable Keychain access control for device unlock"
```

---

### Task 2: `AutoLockController` — optional "never" timeout + lock-on-sleep toggle

**Files:**
- Modify: `MyPass/State/AutoLockController.swift` (full current content below)
- Create: `MyPass/State/AutoLockIdleTimeout.swift`
- Modify: `MyPassTests/AutoLockControllerTests.swift` (full current content below — append two new test methods)

**Interfaces:**
- Produces: `AutoLockController.timeout: TimeInterval?` (changed from non-optional `TimeInterval`; `nil` means "never auto-lock"). Existing call sites passing a plain `TimeInterval` literal (e.g. `timeout: 60`) keep compiling unchanged via Swift's automatic Optional-wrapping at the call site.
- Produces: `AutoLockController.lockOnSleepEnabled: Bool` (new property, settable; `init(...)` gains `lockOnSleepEnabled: Bool = true` with a default so all 3 existing test call sites and the `MyPassApp.swift` construction site keep compiling unchanged).
- Produces: `enum AutoLockIdleTimeout: String, CaseIterable, Identifiable { case immediately, oneMinute, fiveMinutes, fifteenMinutes, thirtyMinutes, oneHour, fourHours, never }` with `var pickerLabel: String` and `var seconds: TimeInterval?` (nil for `.never`).

Current full content of `MyPass/State/AutoLockController.swift` (64 lines):

```swift
import Foundation
import AppKit

protocol AutoLockClock {
    func scheduleTick(after seconds: TimeInterval, _ action: @escaping () -> Void) -> AutoLockCancelable
}

protocol AutoLockCancelable {
    func cancel()
}

protocol AutoLockSleepObserving {
    func onWillSleep(_ handler: @escaping () -> Void) -> AutoLockCancelable
}

final class AutoLockController: ObservableObject {
    private let vaultSession: VaultSession
    private let clock: AutoLockClock
    private var pendingTick: AutoLockCancelable?
    private var sleepSubscription: AutoLockCancelable?

    var timeout: TimeInterval {
        didSet { recordActivity() }
    }

    init(vaultSession: VaultSession, clock: AutoLockClock, sleepObserver: AutoLockSleepObserving, timeout: TimeInterval) {
        self.vaultSession = vaultSession
        self.clock = clock
        self.timeout = timeout
        self.sleepSubscription = sleepObserver.onWillSleep { [weak self] in
            self?.lockNow()
        }
        recordActivity()
    }

    func recordActivity() {
        pendingTick?.cancel()
        pendingTick = clock.scheduleTick(after: timeout) { [weak self] in
            self?.lockNow()
        }
    }

    func lockNow() {
        vaultSession.lock()
    }
}

final class NSWorkspaceSleepObserver: AutoLockSleepObserving {
    func onWillSleep(_ handler: @escaping () -> Void) -> AutoLockCancelable {
        let token = NotificationCenter.default.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { _ in handler() }
        return NotificationTokenCancelable(token: token)
    }
}

final class NotificationTokenCancelable: AutoLockCancelable {
    private let token: NSObjectProtocol
    init(token: NSObjectProtocol) { self.token = token }
    func cancel() { NotificationCenter.default.removeObserver(token) }
}
```

Current full content of `MyPassTests/AutoLockControllerTests.swift` (85 lines):

```swift
import XCTest
@testable import MyPass

final class FakeCancelable: AutoLockCancelable {
    var cancelled = false
    func cancel() { cancelled = true }
}

final class FakeClock: AutoLockClock {
    var scheduled: [(seconds: TimeInterval, action: () -> Void)] = []

    func scheduleTick(after seconds: TimeInterval, _ action: @escaping () -> Void) -> AutoLockCancelable {
        scheduled.append((seconds, action))
        return FakeCancelable()
    }

    func fireLast() {
        scheduled.last?.action()
    }
}

final class FakeSleepObserver: AutoLockSleepObserving {
    var handlers: [() -> Void] = []

    func onWillSleep(_ handler: @escaping () -> Void) -> AutoLockCancelable {
        handlers.append(handler)
        return FakeCancelable()
    }

    func fireSleep() {
        handlers.forEach { $0() }
    }
}

final class AutoLockControllerTests: XCTestCase {
    func testInactivityTimeoutLocksVault() throws {
        let fileStore = VaultFileStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let session = VaultSession(fileStore: fileStore)
        try session.unlock(password: "pw")

        let clock = FakeClock()
        let sleepObserver = FakeSleepObserver()
        let controller = AutoLockController(vaultSession: session, clock: clock, sleepObserver: sleepObserver, timeout: 60)

        clock.fireLast()

        XCTAssertEqual(session.state, .locked)
        _ = controller  // Keep reference to controller
    }

    func testSleepNotificationLocksVault() throws {
        let fileStore = VaultFileStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let session = VaultSession(fileStore: fileStore)
        try session.unlock(password: "pw")

        let clock = FakeClock()
        let sleepObserver = FakeSleepObserver()
        let controller = AutoLockController(vaultSession: session, clock: clock, sleepObserver: sleepObserver, timeout: 900)

        sleepObserver.fireSleep()

        XCTAssertEqual(session.state, .locked)
        _ = controller  // Keep reference to controller
    }

    func testRecordActivityCancelsPreviousTick() throws {
        let fileStore = VaultFileStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let session = VaultSession(fileStore: fileStore)
        try session.unlock(password: "pw")

        let clock = FakeClock()
        let sleepObserver = FakeSleepObserver()
        let controller = AutoLockController(vaultSession: session, clock: clock, sleepObserver: sleepObserver, timeout: 60)

        let firstCancelable = clock.scheduled.last
        controller.recordActivity()

        XCTAssertTrue((firstCancelable != nil))
        // The controller must have scheduled a second tick; firing only the newest one should still lock.
        clock.fireLast()
        XCTAssertEqual(session.state, .locked)
        _ = controller  // Keep reference to controller
    }
}
```

- [ ] **Step 1: Write the failing tests**

Append these two methods inside `final class AutoLockControllerTests { ... }` in `MyPassTests/AutoLockControllerTests.swift`, just before the closing brace of the class:

```swift
    func testNilTimeoutNeverSchedulesATick() throws {
        let fileStore = VaultFileStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let session = VaultSession(fileStore: fileStore)
        try session.unlock(password: "pw")

        let clock = FakeClock()
        let sleepObserver = FakeSleepObserver()
        let controller = AutoLockController(vaultSession: session, clock: clock, sleepObserver: sleepObserver, timeout: nil)

        XCTAssertTrue(clock.scheduled.isEmpty)
        XCTAssertEqual(session.state, .unlocked(try XCTUnwrap(session.currentDatabase)))
    }

    func testLockOnSleepDisabledDoesNotLockOnSleep() throws {
        let fileStore = VaultFileStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let session = VaultSession(fileStore: fileStore)
        try session.unlock(password: "pw")

        let clock = FakeClock()
        let sleepObserver = FakeSleepObserver()
        let controller = AutoLockController(
            vaultSession: session,
            clock: clock,
            sleepObserver: sleepObserver,
            timeout: 900,
            lockOnSleepEnabled: false
        )

        sleepObserver.fireSleep()

        XCTAssertEqual(session.state, .unlocked(try XCTUnwrap(session.currentDatabase)))
        _ = controller  // Keep reference to controller
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/generate.sh && xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/AutoLockControllerTests`
Expected: FAIL to build — `timeout: nil` doesn't type-check against non-optional `TimeInterval`, and `lockOnSleepEnabled:` is not a recognized parameter yet.

- [ ] **Step 3: Implement the changes**

Replace the full content of `MyPass/State/AutoLockController.swift` with:

```swift
import Foundation
import AppKit

protocol AutoLockClock {
    func scheduleTick(after seconds: TimeInterval, _ action: @escaping () -> Void) -> AutoLockCancelable
}

protocol AutoLockCancelable {
    func cancel()
}

protocol AutoLockSleepObserving {
    func onWillSleep(_ handler: @escaping () -> Void) -> AutoLockCancelable
}

final class AutoLockController: ObservableObject {
    private let vaultSession: VaultSession
    private let clock: AutoLockClock
    private var pendingTick: AutoLockCancelable?
    private var sleepSubscription: AutoLockCancelable?

    /// `nil` means "never auto-lock on inactivity".
    var timeout: TimeInterval? {
        didSet { recordActivity() }
    }

    var lockOnSleepEnabled: Bool

    init(
        vaultSession: VaultSession,
        clock: AutoLockClock,
        sleepObserver: AutoLockSleepObserving,
        timeout: TimeInterval?,
        lockOnSleepEnabled: Bool = true
    ) {
        self.vaultSession = vaultSession
        self.clock = clock
        self.timeout = timeout
        self.lockOnSleepEnabled = lockOnSleepEnabled
        self.sleepSubscription = sleepObserver.onWillSleep { [weak self] in
            guard self?.lockOnSleepEnabled == true else { return }
            self?.lockNow()
        }
        recordActivity()
    }

    func recordActivity() {
        pendingTick?.cancel()
        guard let timeout else {
            pendingTick = nil
            return
        }
        pendingTick = clock.scheduleTick(after: timeout) { [weak self] in
            self?.lockNow()
        }
    }

    func lockNow() {
        vaultSession.lock()
    }
}

final class NSWorkspaceSleepObserver: AutoLockSleepObserving {
    func onWillSleep(_ handler: @escaping () -> Void) -> AutoLockCancelable {
        let token = NotificationCenter.default.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { _ in handler() }
        return NotificationTokenCancelable(token: token)
    }
}

final class NotificationTokenCancelable: AutoLockCancelable {
    private let token: NSObjectProtocol
    init(token: NSObjectProtocol) { self.token = token }
    func cancel() { NotificationCenter.default.removeObserver(token) }
}
```

Create `MyPass/State/AutoLockIdleTimeout.swift`:

```swift
import Foundation

enum AutoLockIdleTimeout: String, CaseIterable, Identifiable {
    case immediately, oneMinute, fiveMinutes, fifteenMinutes, thirtyMinutes, oneHour, fourHours, never

    var id: String { rawValue }

    var pickerLabel: String {
        switch self {
        case .immediately: return "Immediately"
        case .oneMinute: return "1 minute"
        case .fiveMinutes: return "5 minutes"
        case .fifteenMinutes: return "15 minutes"
        case .thirtyMinutes: return "30 minutes"
        case .oneHour: return "1 hour"
        case .fourHours: return "4 hours"
        case .never: return "Never"
        }
    }

    /// Idle duration in seconds before auto-lock fires, or `nil` for "never lock".
    var seconds: TimeInterval? {
        switch self {
        case .immediately: return 0
        case .oneMinute: return 60
        case .fiveMinutes: return 5 * 60
        case .fifteenMinutes: return 15 * 60
        case .thirtyMinutes: return 30 * 60
        case .oneHour: return 3600
        case .fourHours: return 4 * 3600
        case .never: return nil
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/generate.sh && xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/AutoLockControllerTests`
Expected: PASS (all 5 methods, the 3 original plus the 2 new ones). As with Task 1, the full app/test target will not build cleanly yet — scope test runs with `-only-testing:` until Task 4 lands.

- [ ] **Step 5: Commit**

```bash
git add MyPass/State/AutoLockController.swift MyPass/State/AutoLockIdleTimeout.swift MyPassTests/AutoLockControllerTests.swift
git commit -m "feat: support never-auto-lock and toggleable lock-on-sleep"
```

---

### Task 3: `UnlockWindowPolicy` + device/account-password window enums

**Files:**
- Create: `MyPass/State/UnlockWindowPolicy.swift`
- Test: `MyPassTests/UnlockWindowPolicyTests.swift`

**Interfaces:**
- Produces: `enum UnlockDeviceWindow: String, CaseIterable, Identifiable { case oneHour, fourHours, eightHours, twentyFourHours, never }` with `var pickerLabel: String` and `var seconds: TimeInterval?`.
- Produces: `enum RequirePasswordWindow: String, CaseIterable, Identifiable { case oneDay, sevenDays, fourteenDays, thirtyDays, ninetyDays, never }` with `var pickerLabel: String` and `var seconds: TimeInterval?`.
- Produces: `enum UnlockWindowPolicy { static func deviceAuthAllowed(now: Date, lastDeviceUnlock: Date?, lastFullPasswordEntry: Date?, deviceWindow: UnlockDeviceWindow, accountPasswordWindow: RequirePasswordWindow) -> Bool }`.

- [ ] **Step 1: Write the failing test**

Create `MyPassTests/UnlockWindowPolicyTests.swift`:

```swift
import XCTest
@testable import MyPass

final class UnlockWindowPolicyTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_000_000)

    func testDisallowedWhenNeverUnlockedByDeviceOrPassword() {
        XCTAssertFalse(
            UnlockWindowPolicy.deviceAuthAllowed(
                now: now,
                lastDeviceUnlock: nil,
                lastFullPasswordEntry: nil,
                deviceWindow: .never,
                accountPasswordWindow: .never
            )
        )
    }

    func testAllowedWithinBothWindows() {
        XCTAssertTrue(
            UnlockWindowPolicy.deviceAuthAllowed(
                now: now,
                lastDeviceUnlock: now.addingTimeInterval(-3600),
                lastFullPasswordEntry: now.addingTimeInterval(-86400),
                deviceWindow: .eightHours,
                accountPasswordWindow: .thirtyDays
            )
        )
    }

    func testDisallowedWhenDeviceWindowElapsed() {
        XCTAssertFalse(
            UnlockWindowPolicy.deviceAuthAllowed(
                now: now,
                lastDeviceUnlock: now.addingTimeInterval(-9 * 3600),
                lastFullPasswordEntry: now.addingTimeInterval(-86400),
                deviceWindow: .eightHours,
                accountPasswordWindow: .thirtyDays
            )
        )
    }

    func testDisallowedWhenAccountPasswordWindowElapsed() {
        XCTAssertFalse(
            UnlockWindowPolicy.deviceAuthAllowed(
                now: now,
                lastDeviceUnlock: now.addingTimeInterval(-3600),
                lastFullPasswordEntry: now.addingTimeInterval(-31 * 86400),
                deviceWindow: .eightHours,
                accountPasswordWindow: .thirtyDays
            )
        )
    }

    func testNeverWindowMeansUnlimitedOnceAnEventHasHappened() {
        XCTAssertTrue(
            UnlockWindowPolicy.deviceAuthAllowed(
                now: now,
                lastDeviceUnlock: now.addingTimeInterval(-365 * 86400),
                lastFullPasswordEntry: now.addingTimeInterval(-365 * 86400),
                deviceWindow: .never,
                accountPasswordWindow: .never
            )
        )
    }

    func testExactBoundaryIsAllowed() {
        XCTAssertTrue(
            UnlockWindowPolicy.deviceAuthAllowed(
                now: now,
                lastDeviceUnlock: now.addingTimeInterval(-8 * 3600),
                lastFullPasswordEntry: now.addingTimeInterval(-30 * 86400),
                deviceWindow: .eightHours,
                accountPasswordWindow: .thirtyDays
            )
        )
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/generate.sh && xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/UnlockWindowPolicyTests`
Expected: FAIL to build — none of `UnlockWindowPolicy`, `UnlockDeviceWindow`, `RequirePasswordWindow` exist yet.

- [ ] **Step 3: Implement**

Create `MyPass/State/UnlockWindowPolicy.swift`:

```swift
import Foundation

enum UnlockDeviceWindow: String, CaseIterable, Identifiable {
    case oneHour, fourHours, eightHours, twentyFourHours, never

    var id: String { rawValue }

    var pickerLabel: String {
        switch self {
        case .oneHour: return "For 1 hour"
        case .fourHours: return "For 4 hours"
        case .eightHours: return "For 8 hours"
        case .twentyFourHours: return "For 24 hours"
        case .never: return "Never"
        }
    }

    /// Window length in seconds, or `nil` for "never expires".
    var seconds: TimeInterval? {
        switch self {
        case .oneHour: return 3600
        case .fourHours: return 4 * 3600
        case .eightHours: return 8 * 3600
        case .twentyFourHours: return 24 * 3600
        case .never: return nil
        }
    }
}

enum RequirePasswordWindow: String, CaseIterable, Identifiable {
    case oneDay, sevenDays, fourteenDays, thirtyDays, ninetyDays, never

    var id: String { rawValue }

    var pickerLabel: String {
        switch self {
        case .oneDay: return "After 1 day"
        case .sevenDays: return "After 7 days"
        case .fourteenDays: return "After 14 days"
        case .thirtyDays: return "After 30 days"
        case .ninetyDays: return "After 90 days"
        case .never: return "Never"
        }
    }

    /// Window length in seconds, or `nil` for "never expires".
    var seconds: TimeInterval? {
        switch self {
        case .oneDay: return 86400
        case .sevenDays: return 7 * 86400
        case .fourteenDays: return 14 * 86400
        case .thirtyDays: return 30 * 86400
        case .ninetyDays: return 90 * 86400
        case .never: return nil
        }
    }
}

enum UnlockWindowPolicy {
    /// Whether device-based unlock (Touch ID / Mac password) may be offered right now,
    /// given when it and the real master password were each last used successfully.
    /// `nil` timestamps mean "never happened" and always return `false`, even if a
    /// window is `.never` (unlimited) — an unlimited window only excuses the passage
    /// of time since a *real* event, not the absence of one.
    static func deviceAuthAllowed(
        now: Date,
        lastDeviceUnlock: Date?,
        lastFullPasswordEntry: Date?,
        deviceWindow: UnlockDeviceWindow,
        accountPasswordWindow: RequirePasswordWindow
    ) -> Bool {
        guard let lastDeviceUnlock, let lastFullPasswordEntry else {
            return false
        }
        if let deviceSeconds = deviceWindow.seconds {
            guard now.timeIntervalSince(lastDeviceUnlock) <= deviceSeconds else { return false }
        }
        if let accountSeconds = accountPasswordWindow.seconds {
            guard now.timeIntervalSince(lastFullPasswordEntry) <= accountSeconds else { return false }
        }
        return true
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/generate.sh && xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/UnlockWindowPolicyTests`
Expected: PASS (all 6 methods).

- [ ] **Step 5: Commit**

```bash
git add MyPass/State/UnlockWindowPolicy.swift MyPassTests/UnlockWindowPolicyTests.swift
git commit -m "feat: add pure policy for device-unlock re-auth windows"
```

---

### Task 4: `DeviceUnlockEnrollment` (replaces `VaultBiometricEnrollment`)

**Files:**
- Create: `MyPass/Security/DeviceUnlockEnrollment.swift`
- Delete: `MyPass/UI/Settings/VaultBiometricEnrollment.swift`
- Delete: `MyPassTests/SecuritySettingsTouchIDTests.swift`
- Test: `MyPassTests/DeviceUnlockEnrollmentTests.swift`

**Interfaces:**
- Consumes: `DeviceUnlockAccessControl` (Task 1), `BiometricKeyStoring` (Task 1's updated 3-arg `store`).
- Produces: `enum DeviceUnlockError: Error, Equatable { case invalidPasswordEncoding, notEnrolled }`.
- Produces: `enum DeviceUnlockEnrollment { static let account: String; static func isEnrolled(biometricKeyStore: BiometricKeyStoring) -> Bool; static func enroll(password: String, accessControl: DeviceUnlockAccessControl, biometricKeyStore: BiometricKeyStoring) throws; static func retrievePassword(biometricKeyStore: BiometricKeyStoring) throws -> String; static func remove(biometricKeyStore: BiometricKeyStoring) throws }`. Used by Task 5 (`SecuritySettingsPane`) and Task 6 (`UnlockView`).

This task deletes the file `MyPass/UI/Settings/VaultBiometricEnrollment.swift`, whose current full content (for reference, to confirm what is being removed) is:

```swift
import Foundation
import MyPassKit

enum VaultBiometricEnrollment {
    static let account = "master"

    static func deriveTransformedKey(password: String, vaultData: Data) throws -> Data {
        try KdbxDatabase.deriveTransformedKey(fromVaultData: vaultData, password: password)
    }

    static func isEnrolled(biometricKeyStore: BiometricKeyStoring) -> Bool {
        (try? biometricKeyStore.hasStoredKey(account: account)) ?? false
    }

    static func enroll(
        password: String,
        vaultData: Data,
        biometricKeyStore: BiometricKeyStoring
    ) throws {
        let derivedKey = try deriveTransformedKey(password: password, vaultData: vaultData)
        try biometricKeyStore.store(derivedKey: derivedKey, account: account)
    }

    static func remove(biometricKeyStore: BiometricKeyStoring) throws {
        try biometricKeyStore.remove(account: account)
    }
}
```

It also deletes `MyPassTests/SecuritySettingsTouchIDTests.swift` (75 lines), which exercises the type above and the old 2-arg `store` — it would no longer compile after this task and is fully superseded by `DeviceUnlockEnrollmentTests.swift` below.

- [ ] **Step 1: Write the failing test**

Create `MyPassTests/DeviceUnlockEnrollmentTests.swift`:

```swift
import XCTest
import MyPassKit
@testable import MyPass

final class DeviceUnlockEnrollmentTests: XCTestCase {
    var tempDir: URL!
    var fileStore: VaultFileStore!
    var biometricKeyStore: FakeBiometricKeyStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceUnlockEnrollmentTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        fileStore = VaultFileStore(directory: tempDir)
        biometricKeyStore = FakeBiometricKeyStore()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testIsEnrolledReflectsFakeStoreState() throws {
        XCTAssertFalse(DeviceUnlockEnrollment.isEnrolled(biometricKeyStore: biometricKeyStore))

        try DeviceUnlockEnrollment.enroll(
            password: "correct-horse",
            accessControl: .touchID,
            biometricKeyStore: biometricKeyStore
        )

        XCTAssertTrue(DeviceUnlockEnrollment.isEnrolled(biometricKeyStore: biometricKeyStore))
    }

    func testEnrollStoresPlaintextPasswordRetrievableLater() throws {
        let session = VaultSession(fileStore: fileStore)
        try session.unlock(password: "correct-horse")

        try DeviceUnlockEnrollment.enroll(
            password: "correct-horse",
            accessControl: .touchIDOrDevicePassword,
            biometricKeyStore: biometricKeyStore
        )

        let retrieved = try DeviceUnlockEnrollment.retrievePassword(biometricKeyStore: biometricKeyStore)
        XCTAssertEqual(retrieved, "correct-horse")
    }

    func testEnrollUsesRequestedAccessControl() throws {
        try DeviceUnlockEnrollment.enroll(
            password: "correct-horse",
            accessControl: .devicePassword,
            biometricKeyStore: biometricKeyStore
        )

        XCTAssertEqual(biometricKeyStore.accessControls[DeviceUnlockEnrollment.account], .devicePassword)
    }

    func testRetrievePasswordThrowsWhenNotEnrolled() {
        XCTAssertThrowsError(try DeviceUnlockEnrollment.retrievePassword(biometricKeyStore: biometricKeyStore)) { error in
            XCTAssertEqual(error as? DeviceUnlockError, .notEnrolled)
        }
    }

    func testRemoveClearsEnrollment() throws {
        try DeviceUnlockEnrollment.enroll(
            password: "correct-horse",
            accessControl: .touchID,
            biometricKeyStore: biometricKeyStore
        )
        XCTAssertTrue(DeviceUnlockEnrollment.isEnrolled(biometricKeyStore: biometricKeyStore))

        try DeviceUnlockEnrollment.remove(biometricKeyStore: biometricKeyStore)

        XCTAssertFalse(DeviceUnlockEnrollment.isEnrolled(biometricKeyStore: biometricKeyStore))
        XCTAssertThrowsError(try DeviceUnlockEnrollment.retrievePassword(biometricKeyStore: biometricKeyStore)) { error in
            XCTAssertEqual(error as? DeviceUnlockError, .notEnrolled)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails, then remove the superseded files**

Run: `./scripts/generate.sh && xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/DeviceUnlockEnrollmentTests`
Expected: FAIL to build — `DeviceUnlockEnrollment` and `DeviceUnlockError` do not exist yet.

Delete the two superseded files now (they will not compile once Task 1's protocol change is in place, and are fully replaced by this task):

```bash
git rm MyPass/UI/Settings/VaultBiometricEnrollment.swift MyPassTests/SecuritySettingsTouchIDTests.swift
```

- [ ] **Step 3: Implement `DeviceUnlockEnrollment`**

Create `MyPass/Security/DeviceUnlockEnrollment.swift`:

```swift
import Foundation

enum DeviceUnlockError: Error, Equatable {
    case invalidPasswordEncoding
    case notEnrolled
}

enum DeviceUnlockEnrollment {
    static let account = "deviceUnlockPassword"

    static func isEnrolled(biometricKeyStore: BiometricKeyStoring) -> Bool {
        (try? biometricKeyStore.hasStoredKey(account: account)) ?? false
    }

    static func enroll(
        password: String,
        accessControl: DeviceUnlockAccessControl,
        biometricKeyStore: BiometricKeyStoring
    ) throws {
        guard let data = password.data(using: .utf8) else {
            throw DeviceUnlockError.invalidPasswordEncoding
        }
        try biometricKeyStore.store(derivedKey: data, account: account, accessControl: accessControl)
    }

    static func retrievePassword(biometricKeyStore: BiometricKeyStoring) throws -> String {
        guard let data = try biometricKeyStore.retrieve(account: account),
              let password = String(data: data, encoding: .utf8) else {
            throw DeviceUnlockError.notEnrolled
        }
        return password
    }

    static func remove(biometricKeyStore: BiometricKeyStoring) throws {
        try biometricKeyStore.remove(account: account)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/generate.sh && xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/DeviceUnlockEnrollmentTests`
Expected: PASS (all 5 methods). At this point `MyPass/UI/Settings/SecuritySettingsPane.swift` and `MyPass/UI/Unlock/UnlockView.swift` still reference the now-deleted `VaultBiometricEnrollment` and the old 2-arg `store`, so the full app target still will not build — this is resolved by Tasks 5 and 6. Continue scoping test runs with `-only-testing:` until Task 6 lands.

- [ ] **Step 5: Commit**

```bash
git add MyPass/Security/DeviceUnlockEnrollment.swift MyPassTests/DeviceUnlockEnrollmentTests.swift
git commit -m "feat: replace derived-key Touch ID enrollment with password-based device unlock"
```

---

### Task 5: Rewrite `SecuritySettingsPane` — Unlock + Auto-lock sections

**Files:**
- Modify: `MyPass/UI/Settings/SecuritySettingsPane.swift` (full replacement; current full content already reproduced in Task 4's sibling context and above in this plan's research — reproduced again below for this task's self-containedness)

**Interfaces:**
- Consumes: `DeviceUnlockAccessControl.forToggles` (Task 1), `AutoLockController.timeout: TimeInterval?` / `.lockOnSleepEnabled` (Task 2), `AutoLockIdleTimeout` (Task 2), `UnlockDeviceWindow` / `RequirePasswordWindow` (Task 3), `DeviceUnlockEnrollment.{isEnrolled,enroll,retrievePassword,remove}` (Task 4), `KdbxDatabase.open(data:password:)` / `KdbxDatabaseError.wrongPassword` (existing, `MyPassKit`).
- Produces (as `@AppStorage` string-literal keys, duplicated verbatim in Task 6 — keep both in sync): `"unlockTouchIDEnabled"` (Bool), `"unlockMacPasswordEnabled"` (Bool), `"unlockWithDeviceWindow"` (`UnlockDeviceWindow`), `"requireAccountPasswordWindow"` (`RequirePasswordWindow`), `"lockOnDeviceSleepEnabled"` (Bool), `"autoLockIdleTimeout"` (`AutoLockIdleTimeout`).

This task has no dedicated new XCTest file — consistent with the existing convention confirmed by research (the previous Touch ID tests exercised `VaultBiometricEnrollment` directly, never the SwiftUI view itself; the underlying logic this view calls is already fully covered by Tasks 1, 3, and 4). Verification for this task is: the project builds, and a manual walkthrough of Settings → Security in the running app.

The current full content of `MyPass/UI/Settings/SecuritySettingsPane.swift` (174 lines) that this task replaces entirely:

```swift
import SwiftUI
import MyPassKit

struct SecuritySettingsPane: View {
    @AppStorage("autoLockTimeoutMinutes") private var autoLockTimeoutMinutes: Double = 15
    @AppStorage("clipboardClearSeconds") private var clipboardClearSeconds: Int = 30
    @EnvironmentObject private var autoLockController: AutoLockController
    @EnvironmentObject private var vaultSession: VaultSession

    @State private var touchIDEnabled = false
    @State private var touchIDError: String?
    @State private var confirmPassword = ""
    @State private var showConfirmSheet = false

    let biometricKeyStore: BiometricKeyStoring

    init(biometricKeyStore: BiometricKeyStoring = BiometricKeyStore()) {
        self.biometricKeyStore = biometricKeyStore
    }

    private var touchIDBinding: Binding<Bool> {
        Binding(
            get: { touchIDEnabled },
            set: { newValue in
                if newValue {
                    enableTouchID()
                } else {
                    disableTouchID()
                }
            }
        )
    }

    var body: some View {
        Form {
            Section {
                Stepper("Lock automatically after inactivity: \(Int(autoLockTimeoutMinutes)) min",
                        value: $autoLockTimeoutMinutes, in: 1...120)
                SettingsHelperText(text: "Lock the vault after inactivity so passwords stay protected when you step away.")
            } header: {
                Text("Auto-Lock")
            }

            Section {
                Toggle("Unlock with Touch ID", isOn: touchIDBinding)
                SettingsHelperText(text: "Use Touch ID to unlock without typing your master password; after restart, master password is still required per security model.")
                if let touchIDError {
                    Text(touchIDError)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            } header: {
                Text("Touch ID")
            }

            Section {
                Stepper("Clear clipboard after: \(clipboardClearSeconds) s",
                        value: $clipboardClearSeconds, in: 10...120, step: 5)
                SettingsHelperText(text: "Usernames, passwords, and codes copied from MyPass are removed from the clipboard after this interval.")
            } header: {
                Text("Clipboard")
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            autoLockController.timeout = autoLockTimeoutMinutes * 60
            refreshTouchIDState()
        }
        .onChange(of: autoLockTimeoutMinutes) { _, newValue in
            autoLockController.timeout = newValue * 60
        }
        .sheet(isPresented: $showConfirmSheet) {
            touchIDConfirmSheet
        }
    }

    private var touchIDConfirmSheet: some View {
        VStack(spacing: 16) {
            Text("Confirm Master Password")
                .font(.headline)

            Text("Enter your master password to enroll Touch ID for this vault.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            SecureField("Master Password", text: $confirmPassword)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
                .onSubmit(confirmTouchIDEnrollment)

            HStack {
                Button("Cancel") {
                    confirmPassword = ""
                    showConfirmSheet = false
                    touchIDEnabled = VaultBiometricEnrollment.isEnrolled(biometricKeyStore: biometricKeyStore)
                }
                Spacer()
                Button("Enroll") {
                    confirmTouchIDEnrollment()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(confirmPassword.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 360)
    }

    private func refreshTouchIDState() {
        touchIDEnabled = VaultBiometricEnrollment.isEnrolled(biometricKeyStore: biometricKeyStore)
    }

    private func enableTouchID() {
        touchIDError = nil
        guard vaultSession.currentDatabase != nil else {
            touchIDError = "Unlock the vault before enabling Touch ID."
            touchIDEnabled = false
            return
        }
        showConfirmSheet = true
    }

    private func disableTouchID() {
        touchIDError = nil
        do {
            try VaultBiometricEnrollment.remove(biometricKeyStore: biometricKeyStore)
            touchIDEnabled = false
        } catch {
            touchIDError = "Could not remove Touch ID enrollment."
            touchIDEnabled = true
        }
    }

    private func confirmTouchIDEnrollment() {
        touchIDError = nil
        do {
            guard vaultSession.currentDatabase != nil else {
                throw VaultSessionError.notUnlocked
            }
            guard let vaultData = try vaultSession.loadVaultData() else {
                touchIDError = "No vault data found."
                touchIDEnabled = false
                confirmPassword = ""
                showConfirmSheet = false
                return
            }
            try VaultBiometricEnrollment.enroll(
                password: confirmPassword,
                vaultData: vaultData,
                biometricKeyStore: biometricKeyStore
            )
            touchIDEnabled = true
            confirmPassword = ""
            showConfirmSheet = false
        } catch let error as KdbxDatabaseError where error == .wrongPassword {
            touchIDError = "Incorrect master password."
            touchIDEnabled = false
            confirmPassword = ""
            showConfirmSheet = false
        } catch is VaultSessionError {
            touchIDError = "Unlock the vault before enabling Touch ID."
            touchIDEnabled = false
            confirmPassword = ""
            showConfirmSheet = false
        } catch {
            touchIDError = "Touch ID enrollment failed."
            touchIDEnabled = false
            confirmPassword = ""
            showConfirmSheet = false
        }
    }
}
```

- [ ] **Step 1: Replace the file**

Replace the full content of `MyPass/UI/Settings/SecuritySettingsPane.swift` with:

```swift
import SwiftUI
import MyPassKit

struct SecuritySettingsPane: View {
    @AppStorage("unlockTouchIDEnabled") private var touchIDEnabled = false
    @AppStorage("unlockMacPasswordEnabled") private var macPasswordEnabled = false
    @AppStorage("unlockWithDeviceWindow") private var unlockWithDeviceWindow: UnlockDeviceWindow = .eightHours
    @AppStorage("requireAccountPasswordWindow") private var requireAccountPasswordWindow: RequirePasswordWindow = .thirtyDays
    @AppStorage("lockOnDeviceSleepEnabled") private var lockOnDeviceSleepEnabled = true
    @AppStorage("autoLockIdleTimeout") private var autoLockIdleTimeout: AutoLockIdleTimeout = .thirtyMinutes
    @AppStorage("clipboardClearSeconds") private var clipboardClearSeconds: Int = 30
    @EnvironmentObject private var autoLockController: AutoLockController
    @EnvironmentObject private var vaultSession: VaultSession

    @State private var unlockError: String?
    @State private var confirmPassword = ""
    @State private var showConfirmSheet = false
    @State private var pendingAccessControl: DeviceUnlockAccessControl?

    let biometricKeyStore: BiometricKeyStoring

    init(biometricKeyStore: BiometricKeyStoring = BiometricKeyStore()) {
        self.biometricKeyStore = biometricKeyStore
    }

    private var touchIDBinding: Binding<Bool> {
        Binding(
            get: { touchIDEnabled },
            set: { newValue in
                touchIDEnabled = newValue
                updateDeviceUnlockEnrollment()
            }
        )
    }

    private var macPasswordBinding: Binding<Bool> {
        Binding(
            get: { macPasswordEnabled },
            set: { newValue in
                macPasswordEnabled = newValue
                updateDeviceUnlockEnrollment()
            }
        )
    }

    var body: some View {
        Form {
            Section {
                Toggle("Unlock using Touch ID", isOn: touchIDBinding)
                Toggle("Unlock app with Mac password", isOn: macPasswordBinding)

                Picker("Unlock with device:", selection: $unlockWithDeviceWindow) {
                    ForEach(UnlockDeviceWindow.allCases) { window in
                        Text(window.pickerLabel).tag(window)
                    }
                }

                Picker("Require account password:", selection: $requireAccountPasswordWindow) {
                    ForEach(RequirePasswordWindow.allCases) { window in
                        Text(window.pickerLabel).tag(window)
                    }
                }

                SettingsHelperText(text: "Unlock without typing your master password using Touch ID or your Mac password. You'll still be asked for the master password on the schedule above.")

                if let unlockError {
                    Text(unlockError)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            } header: {
                Text("Unlock")
            }

            Section {
                Toggle("Lock when device locks or sleeps", isOn: $lockOnDeviceSleepEnabled)
                Picker("Lock after the device is idle for:", selection: $autoLockIdleTimeout) {
                    ForEach(AutoLockIdleTimeout.allCases) { timeout in
                        Text(timeout.pickerLabel).tag(timeout)
                    }
                }
                SettingsHelperText(text: "Lock the vault after inactivity so passwords stay protected when you step away.")
            } header: {
                Text("Auto-lock")
            }

            Section {
                Stepper("Clear clipboard after: \(clipboardClearSeconds) s",
                        value: $clipboardClearSeconds, in: 10...120, step: 5)
                SettingsHelperText(text: "Usernames, passwords, and codes copied from MyPass are removed from the clipboard after this interval.")
            } header: {
                Text("Clipboard")
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            autoLockController.timeout = autoLockIdleTimeout.seconds
            autoLockController.lockOnSleepEnabled = lockOnDeviceSleepEnabled
        }
        .onChange(of: autoLockIdleTimeout) { _, newValue in
            autoLockController.timeout = newValue.seconds
        }
        .onChange(of: lockOnDeviceSleepEnabled) { _, newValue in
            autoLockController.lockOnSleepEnabled = newValue
        }
        .sheet(isPresented: $showConfirmSheet) {
            confirmSheet
        }
    }

    private var confirmSheet: some View {
        VStack(spacing: 16) {
            Text("Confirm Master Password")
                .font(.headline)

            Text("Enter your master password to enable device unlock for this vault.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            SecureField("Master Password", text: $confirmPassword)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
                .onSubmit(confirmEnrollment)

            HStack {
                Button("Cancel", action: cancelEnrollment)
                Spacer()
                Button("Enable", action: confirmEnrollment)
                    .keyboardShortcut(.defaultAction)
                    .disabled(confirmPassword.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 360)
    }

    private func updateDeviceUnlockEnrollment() {
        unlockError = nil
        guard let accessControl = DeviceUnlockAccessControl.forToggles(
            touchIDEnabled: touchIDEnabled,
            macPasswordEnabled: macPasswordEnabled
        ) else {
            try? DeviceUnlockEnrollment.remove(biometricKeyStore: biometricKeyStore)
            return
        }

        if let existingPassword = try? DeviceUnlockEnrollment.retrievePassword(biometricKeyStore: biometricKeyStore) {
            do {
                try DeviceUnlockEnrollment.enroll(
                    password: existingPassword,
                    accessControl: accessControl,
                    biometricKeyStore: biometricKeyStore
                )
            } catch {
                unlockError = "Could not update device unlock settings."
                touchIDEnabled = false
                macPasswordEnabled = false
            }
            return
        }

        guard vaultSession.currentDatabase != nil else {
            unlockError = "Unlock the vault before enabling device unlock."
            touchIDEnabled = false
            macPasswordEnabled = false
            return
        }
        pendingAccessControl = accessControl
        showConfirmSheet = true
    }

    private func cancelEnrollment() {
        confirmPassword = ""
        showConfirmSheet = false
        pendingAccessControl = nil
        touchIDEnabled = false
        macPasswordEnabled = false
    }

    private func confirmEnrollment() {
        unlockError = nil
        guard let accessControl = pendingAccessControl else {
            showConfirmSheet = false
            return
        }
        do {
            guard let vaultData = try vaultSession.loadVaultData() else {
                unlockError = "No vault data found."
                cancelEnrollment()
                return
            }
            _ = try KdbxDatabase.open(data: vaultData, password: confirmPassword)
            try DeviceUnlockEnrollment.enroll(
                password: confirmPassword,
                accessControl: accessControl,
                biometricKeyStore: biometricKeyStore
            )
            confirmPassword = ""
            showConfirmSheet = false
            pendingAccessControl = nil
        } catch let error as KdbxDatabaseError where error == .wrongPassword {
            unlockError = "Incorrect master password."
            cancelEnrollment()
        } catch {
            unlockError = "Could not enable device unlock."
            cancelEnrollment()
        }
    }
}
```

- [ ] **Step 2: Build and manually verify**

Run: `./scripts/generate.sh && xcodebuild build -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS'`
Expected: builds successfully (the app target will still fail only if `UnlockView.swift` — Task 6 — hasn't been updated yet, since it also references the old 2-arg `store`/`VaultBiometricEnrollment`; if this task is done before Task 6, expect the build to fail specifically in `UnlockView.swift` and nowhere else — confirm any error is confined to that file).

- [ ] **Step 3: Commit**

```bash
git add MyPass/UI/Settings/SecuritySettingsPane.swift
git commit -m "feat: redesign Security settings with Unlock and Auto-lock sections"
```

---

### Task 6: Rewrite `UnlockView` to use device-based unlock

**Files:**
- Modify: `MyPass/UI/Unlock/UnlockView.swift` (full replacement; current full content reproduced below)

**Interfaces:**
- Consumes: `DeviceUnlockEnrollment.{isEnrolled,retrievePassword}` (Task 4), `UnlockWindowPolicy.deviceAuthAllowed` (Task 3), `UnlockDeviceWindow` / `RequirePasswordWindow` (Task 3), `VaultSession.unlock(password:)` (existing, unchanged).
- Produces (as `@AppStorage` string-literal keys, must match Task 5's literals exactly): `"unlockTouchIDEnabled"`, `"unlockMacPasswordEnabled"`, `"unlockWithDeviceWindow"`, `"requireAccountPasswordWindow"`. Also introduces two new keys owned by this file (read here, written here and in the manual-unlock path): `"lastDeviceUnlockTimestamp"` (Double, seconds since 1970; `0` means "never"), `"lastFullPasswordEntryTimestamp"` (Double, same convention).

No dedicated new XCTest file for this task either, for the same reason as Task 5 — this view's only non-trivial logic (`UnlockWindowPolicy.deviceAuthAllowed`) is already fully tested in Task 3, and SwiftUI views are not unit-tested elsewhere in this codebase. Verification is: full project build and test suite (this task is what makes the whole app target compile again after Tasks 4-5 removed the old Touch ID mechanism), plus a manual run.

Current full content of `MyPass/UI/Unlock/UnlockView.swift` (83 lines) that this task replaces entirely:

```swift
import SwiftUI

struct UnlockView: View {
    @EnvironmentObject var vaultSession: VaultSession
    @State private var password: String = ""
    @State private var errorMessage: String?

    let biometricKeyStore: BiometricKeyStoring

    init(biometricKeyStore: BiometricKeyStoring = BiometricKeyStore()) {
        self.biometricKeyStore = biometricKeyStore
    }

    private var hasStoredBiometricKey: Bool {
        (try? biometricKeyStore.retrieve(account: "master")) != nil
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("MyPass")
                .font(.system(size: 28, weight: .semibold))

            Image("BrandKey")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 56, height: 56)
                .padding(.bottom, 4)
                .accessibilityHidden(true)

            SecureField("Master Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
                .onSubmit(attemptUnlock)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            Button("Unlock", action: attemptUnlock)
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: 320)

            if hasStoredBiometricKey {
                Button("Touch ID", systemImage: "touchid", action: attemptBiometricUnlock)
                    .buttonStyle(.bordered)
                    .frame(maxWidth: 320)
            }

            Text("Vault is locked. Enter your master password or use Touch ID.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
                .padding(.top, 8)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func attemptUnlock() {
        do {
            try vaultSession.unlock(password: password)
            password = ""
            errorMessage = nil
        } catch {
            errorMessage = "Incorrect password or corrupted file."
        }
    }

    private func attemptBiometricUnlock() {
        // Placeholder wiring for this task: retrieving the stored derived key succeeds
        // only after Touch ID biometric confirmation (enforced by SecAccessControl on the
        // Keychain item itself, not by this view). Mapping the derived key back into an
        // unlock call is deferred — this button demonstrates the store/retrieve contract end to end.
        errorMessage = (try? biometricKeyStore.retrieve(account: "master")) == nil
            ? "Touch ID is unavailable."
            : nil
    }
}
```

- [ ] **Step 1: Replace the file**

Replace the full content of `MyPass/UI/Unlock/UnlockView.swift` with:

```swift
import SwiftUI

struct UnlockView: View {
    @EnvironmentObject var vaultSession: VaultSession
    @AppStorage("unlockTouchIDEnabled") private var touchIDEnabled = false
    @AppStorage("unlockMacPasswordEnabled") private var macPasswordEnabled = false
    @AppStorage("unlockWithDeviceWindow") private var unlockWithDeviceWindow: UnlockDeviceWindow = .eightHours
    @AppStorage("requireAccountPasswordWindow") private var requireAccountPasswordWindow: RequirePasswordWindow = .thirtyDays
    @AppStorage("lastDeviceUnlockTimestamp") private var lastDeviceUnlockTimestamp: Double = 0
    @AppStorage("lastFullPasswordEntryTimestamp") private var lastFullPasswordEntryTimestamp: Double = 0

    @State private var password: String = ""
    @State private var errorMessage: String?

    let biometricKeyStore: BiometricKeyStoring

    init(biometricKeyStore: BiometricKeyStoring = BiometricKeyStore()) {
        self.biometricKeyStore = biometricKeyStore
    }

    private var deviceUnlockButtonLabel: String {
        switch (touchIDEnabled, macPasswordEnabled) {
        case (true, true): return "Unlock with Touch ID or Password"
        case (true, false): return "Touch ID"
        case (false, true): return "Unlock with Mac Password"
        case (false, false): return ""
        }
    }

    private var deviceUnlockButtonSymbol: String {
        macPasswordEnabled && !touchIDEnabled ? "key.fill" : "touchid"
    }

    private var canShowDeviceUnlockButton: Bool {
        guard touchIDEnabled || macPasswordEnabled else { return false }
        guard DeviceUnlockEnrollment.isEnrolled(biometricKeyStore: biometricKeyStore) else { return false }
        return UnlockWindowPolicy.deviceAuthAllowed(
            now: Date(),
            lastDeviceUnlock: lastDeviceUnlockTimestamp > 0 ? Date(timeIntervalSince1970: lastDeviceUnlockTimestamp) : nil,
            lastFullPasswordEntry: lastFullPasswordEntryTimestamp > 0 ? Date(timeIntervalSince1970: lastFullPasswordEntryTimestamp) : nil,
            deviceWindow: unlockWithDeviceWindow,
            accountPasswordWindow: requireAccountPasswordWindow
        )
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("MyPass")
                .font(.system(size: 28, weight: .semibold))

            Image("BrandKey")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 56, height: 56)
                .padding(.bottom, 4)
                .accessibilityHidden(true)

            SecureField("Master Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
                .onSubmit(attemptUnlock)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            Button("Unlock", action: attemptUnlock)
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: 320)

            if canShowDeviceUnlockButton {
                Button(deviceUnlockButtonLabel, systemImage: deviceUnlockButtonSymbol, action: attemptDeviceUnlock)
                    .buttonStyle(.bordered)
                    .frame(maxWidth: 320)
            }

            Text("Vault is locked. Enter your master password or use Touch ID.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
                .padding(.top, 8)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func attemptUnlock() {
        do {
            try vaultSession.unlock(password: password)
            password = ""
            errorMessage = nil
            let now = Date().timeIntervalSince1970
            lastDeviceUnlockTimestamp = now
            lastFullPasswordEntryTimestamp = now
        } catch {
            errorMessage = "Incorrect password or corrupted file."
        }
    }

    private func attemptDeviceUnlock() {
        do {
            let storedPassword = try DeviceUnlockEnrollment.retrievePassword(biometricKeyStore: biometricKeyStore)
            try vaultSession.unlock(password: storedPassword)
            password = ""
            errorMessage = nil
            lastDeviceUnlockTimestamp = Date().timeIntervalSince1970
        } catch {
            errorMessage = "Device unlock is unavailable. Enter your master password."
        }
    }
}
```

- [ ] **Step 2: Run the full test suite to verify everything compiles and passes together**

Run: `./scripts/generate.sh && xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS'`
Expected: PASS — every test target in `MyPassTests`, including the new files from Tasks 1, 3, 4 and the modified `AutoLockControllerTests.swift` from Task 2, plus every pre-existing test unrelated to this feature.

- [ ] **Step 3: Commit**

```bash
git add MyPass/UI/Unlock/UnlockView.swift
git commit -m "feat: wire real device-based unlock into UnlockView"
```

---

### Task 7: Legacy Keychain cleanup + final verification

**Files:**
- Modify: `MyPass/MyPassApp.swift:147-153` (small, self-contained insertion adjacent to the known `AutoLockController` construction site)

**Interfaces:**
- Consumes: `BiometricKeyStore()` (Task 1, unchanged public API for `remove(account:)`).

This is a best-effort, non-blocking cleanup (per the approved design spec's Risks section): a user who enrolled the old derived-key Touch ID mechanism before this feature shipped has a stale Keychain item under the account `"master"` that nothing in the app reads anymore after Task 4. Deleting it on next launch is harmless if it's already absent (`BiometricKeyStore.remove` treats `errSecItemNotFound` as success) and avoids leaving orphaned Keychain data around.

- [ ] **Step 1: Insert the cleanup call**

In `MyPass/MyPassApp.swift`, find this exact existing block (currently at lines 147-153):

```swift
        let controller = AutoLockController(
            vaultSession: session,
            clock: RealAutoLockClock(),
            sleepObserver: NSWorkspaceSleepObserver(),
            timeout: Self.defaultAutoLockTimeout
        )
        _autoLockController = StateObject(wrappedValue: controller)
```

Replace it with:

```swift
        // Best-effort cleanup of the pre-2026-07-28 Touch ID enrollment, which stored a
        // derived key under a fixed "master" account. Safe to call even if nothing is stored.
        try? BiometricKeyStore().remove(account: "master")

        let controller = AutoLockController(
            vaultSession: session,
            clock: RealAutoLockClock(),
            sleepObserver: NSWorkspaceSleepObserver(),
            timeout: Self.defaultAutoLockTimeout
        )
        _autoLockController = StateObject(wrappedValue: controller)
```

- [ ] **Step 2: Full build and test verification**

Run: `./scripts/test.sh`
Expected: every step passes — `xcodebuild test` for `MyPass`/`MyPassTests`, plus `swift test` for `MyPassKit`, `SyncKit`, `ExtensionBridgeKit` (none of which this plan touches, so they should be unaffected).

- [ ] **Step 3: Confirm no leftover references to the removed mechanism**

Run: `grep -rn "VaultBiometricEnrollment" /Users/lucheninov/Documents/Works/all_sync_docs/mypass/MyPass /Users/lucheninov/Documents/Works/all_sync_docs/mypass/MyPassTests`
Expected: no output (zero matches).

Run: `grep -rn '"master"' /Users/lucheninov/Documents/Works/all_sync_docs/mypass/MyPass/UI/Settings/SecuritySettingsPane.swift /Users/lucheninov/Documents/Works/all_sync_docs/mypass/MyPass/UI/Unlock/UnlockView.swift`
Expected: no output (the old fixed Keychain account literal `"master"` should no longer appear in either rewritten view; it is fine that it still appears in `MyPass/MyPassApp.swift`'s new cleanup line from Step 1, and in `MyPass/Security/BiometricKeyStore.swift` if any doc comments mention it).

- [ ] **Step 4: Manual smoke test**

Use the project's `run` skill (or `./scripts/build_and_run.sh` if present, otherwise build via Xcode and launch `MyPass.app` directly) to launch the app and manually verify:
1. Settings → Security shows the new "Unlock" section (two toggles, two pickers) and redesigned "Auto-lock" section (toggle + picker), in that order, above the existing "Clipboard" section.
2. Turning on "Unlock using Touch ID" with the vault unlocked prompts for the master password via the confirm sheet; entering the correct password enables it without error; entering an incorrect password shows "Incorrect master password." and reverts the toggle.
3. Locking the vault (Cmd+Shift+L or the existing lock shortcut) and reopening shows a "Touch ID" button on the unlock screen alongside the password field; using it unlocks without typing the password.
4. Turning both "Unlock using Touch ID" and "Unlock app with Mac password" on, then off again, cleanly removes device unlock — the unlock screen reverts to password-only.
5. Selecting "Never" for "Lock after the device is idle for:" and confirming (via code inspection or a long wait) that auto-lock does not fire.

- [ ] **Step 5: Commit**

```bash
git add MyPass/MyPassApp.swift
git commit -m "chore: clean up legacy Touch ID Keychain item on launch"
```
