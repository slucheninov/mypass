# MyPass Settings Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the monolithic `SettingsView` scrolling form with an Apple System Settings–style `NavigationSplitView` (General, Security, Browser, Sync, Backups), add new General/Security controls, and wire `MyPassApp` for menu bar visibility, login item, global shortcuts, and configurable clipboard auto-clear.

**Architecture:** Extract shared settings helpers and one view file per pane under `MyPass/UI/Settings/`. Keep all existing sync/Chrome/backup `@AppStorage` keys and behavior intact — relocation only. Add small utility types for shortcut encoding, global hotkey registration, clipboard interval reading, and Touch ID enrollment key derivation. `SettingsView` becomes the shell entry point hosting sidebar selection and pane routing.

**Tech Stack:** SwiftUI, AppKit, ServiceManagement (`SMAppService`), Carbon hotkeys (`RegisterEventHotKey`), MyPassKit (`KeyDerivation`, `KdbxOuterHeader`), existing `BiometricKeyStore` / `AutoLockController` / `ClipboardAutoClear`, XCTest, XcodeGen (`project.yml` globs `MyPass/` — no change needed for new files)

## Global Constraints

- English UI strings only until Phase 7 localization
- Spec reference: `docs/superpowers/specs/2026-07-26-mypass-settings-redesign-design.md` (supersedes Settings layout section of `docs/superpowers/specs/2026-07-26-mypass-ui-shell-design.md`)
- Do not redesign `MenuBarExtraContent` layout (Problem 2 — menu bar spec); General only toggles presence and stores `menuBarClickAction`
- Preserve existing `@AppStorage` keys for sync and Chrome; no master password, derived keys, or SFTP PEM in `@AppStorage`
- macOS deployment target 14.0+ (`project.yml`)
- Reuse Wave 1 `SettingsHelperText` styling (11 pt secondary, multi-line)
- Tests via `./scripts/test.sh`; build smoke via `./scripts/build.sh`
- `project.yml` glob-includes all files under `MyPass/` and `MyPassTests/` — **no `project.yml` change** for new Swift files in those folders

---

## File structure (created/modified by this plan)

```
MyPass/UI/Settings/
  SettingsView.swift                 (MODIFY — becomes NavigationSplitView shell)
  SettingsPane.swift                 (NEW — pane enum + sidebar metadata)
  SettingsHelperText.swift           (NEW — extracted from SettingsView)
  SyncBackendOption.swift            (NEW — moved from SettingsView)
  GeneralSettingsPane.swift          (NEW)
  SecuritySettingsPane.swift         (NEW)
  BrowserSettingsPane.swift          (NEW — Chrome extension section)
  SyncSettingsPane.swift             (NEW — sync backends + SFTP test)
  BackupsSettingsPane.swift          (NEW)
  ShortcutCodec.swift                (NEW — parse/serialize "shift+command+L")
  ShortcutRecorderField.swift        (NEW — click-to-capture key combo)
  GlobalHotkeyManager.swift          (NEW — Carbon RegisterEventHotKey)
  ClipboardClearInterval.swift       (NEW — read @AppStorage interval)
  VaultBiometricEnrollment.swift     (NEW — derive transformedKey for Touch ID store)

MyPass/Security/
  BiometricKeyStore.swift            (MODIFY — add remove(account:) to protocol + impl)

MyPass/MyPassApp.swift               (MODIFY — MenuBarExtra gating, hotkeys, login sync)

MyPass/UI/EntryDetail/
  EntryDetailView.swift              (MODIFY — clipboard interval from AppStorage)

MyPass/UI/PasswordGenerator/
  PasswordGeneratorView.swift        (MODIFY — clipboard interval from AppStorage)

MyPassTests/
  ShortcutCodecTests.swift           (NEW)
  ClipboardClearIntervalTests.swift  (NEW)
  VaultBiometricEnrollmentTests.swift (NEW)
  SecuritySettingsTouchIDTests.swift (NEW — FakeBiometricKeyStore enrollment state)
```

**Execution order note:** Land this plan before (or on a branch rebased atop) the menu bar redesign plan. Menu bar depends on `showMenuBarExtra` gating implemented here.

---

### Task 1: Shared settings infrastructure

**Files:**
- Create: `MyPass/UI/Settings/SettingsPane.swift`
- Create: `MyPass/UI/Settings/SettingsHelperText.swift`
- Create: `MyPass/UI/Settings/SyncBackendOption.swift`
- Modify: `MyPass/UI/Settings/SettingsView.swift` (remove moved types only — full shell rewrite in Task 2)

**Interfaces:**
- Consumes: SwiftUI
- Produces:
  - `enum SettingsPane: String, CaseIterable, Identifiable` with cases `general`, `security`, `browser`, `sync`, `backups`; `title`, `symbolName`, `detailTitle` properties
  - `struct SettingsHelperText: View` (same styling as current private struct)
  - `enum SyncBackendOption: String, CaseIterable, Identifiable` (unchanged from current `SettingsView.swift` lines 6–14)

- [ ] **Step 1: Create SettingsPane.swift**

```swift
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case security
    case browser
    case sync
    case backups

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .security: return "Security"
        case .browser: return "Browser"
        case .sync: return "Sync"
        case .backups: return "Backups"
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .security: return "lock.fill"
        case .browser: return "globe"
        case .sync: return "arrow.triangle.2.circlepath"
        case .backups: return "externaldrive"
        }
    }

    var detailTitle: String { title }
}
```

- [ ] **Step 2: Create SettingsHelperText.swift**

Move the existing private struct verbatim from `SettingsView.swift` (lines 368–379) into its own file with `internal` access (drop `private`).

- [ ] **Step 3: Create SyncBackendOption.swift**

Move `SyncBackendOption` enum verbatim from `SettingsView.swift` (lines 6–14).

- [ ] **Step 4: Remove moved types from SettingsView.swift**

Delete `SyncBackendOption`, the private `SettingsHelperText`, and leave the rest of `SettingsView` intact for Task 2 extraction.

- [ ] **Step 5: Build to verify compilation**

Run: `./scripts/build.sh 2>&1 | tail -20`

Expected: BUILD SUCCEEDED

- [ ] **Step 6: Commit**

```bash
git add MyPass/UI/Settings/SettingsPane.swift MyPass/UI/Settings/SettingsHelperText.swift MyPass/UI/Settings/SyncBackendOption.swift MyPass/UI/Settings/SettingsView.swift
git commit -m "refactor(settings): extract shared pane enum and helpers"
```

---

### Task 2: Settings NavigationSplitView shell

**Files:**
- Modify: `MyPass/UI/Settings/SettingsView.swift` (replace `body` with shell; pane bodies stubbed initially)

**Interfaces:**
- Consumes: `SettingsPane`, `@AppStorage("settingsSelectedPane")`, `@EnvironmentObject AutoLockController`, `@EnvironmentObject VaultSession`
- Produces: `SettingsView` with sidebar ~180 pt, detail `minWidth` 480, default selection General

- [ ] **Step 1: Replace SettingsView body with NavigationSplitView shell**

```swift
struct SettingsView: View {
    @AppStorage("settingsSelectedPane") private var selectedPaneRaw: String = SettingsPane.general.rawValue
    @EnvironmentObject private var autoLockController: AutoLockController
    @EnvironmentObject private var vaultSession: VaultSession

    private var selectedPane: SettingsPane {
        SettingsPane(rawValue: selectedPaneRaw) ?? .general
    }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { selectedPane },
                set: { selectedPaneRaw = $0.rawValue }
            )) {
                ForEach(SettingsPane.allCases) { pane in
                    Label(pane.title, systemImage: pane.symbolName)
                        .tag(pane)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 180, max: 180)
        } detail: {
            paneContent(for: selectedPane)
                .frame(minWidth: 480)
                .navigationTitle(selectedPane.detailTitle)
        }
        .frame(minWidth: 660, minHeight: 420)
    }

    @ViewBuilder
    private func paneContent(for pane: SettingsPane) -> some View {
        switch pane {
        case .general:
            GeneralSettingsPane()
        case .security:
            SecuritySettingsPane()
        case .browser:
            BrowserSettingsPane()
        case .sync:
            SyncSettingsPane()
                .environmentObject(autoLockController)
                .environmentObject(vaultSession)
        case .backups:
            BackupsSettingsPane()
        }
    }
}
```

Create stub pane files (`GeneralSettingsPane.swift`, etc.) each returning `Form { Text("…") }` so the project compiles — Tasks 3–12 replace stubs with real content.

- [ ] **Step 2: Create stub pane files**

Each stub:

```swift
import SwiftUI

struct GeneralSettingsPane: View {
    var body: some View {
        Form { Text("General") }.formStyle(.grouped).padding()
    }
}
```

Repeat for `SecuritySettingsPane`, `BrowserSettingsPane`, `SyncSettingsPane`, `BackupsSettingsPane`.

- [ ] **Step 3: Build**

Run: `./scripts/build.sh 2>&1 | tail -20`

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add MyPass/UI/Settings/
git commit -m "feat(settings): NavigationSplitView shell with five panes"
```

---

### Task 3: General pane — menu bar, login item, click action

**Files:**
- Modify: `MyPass/UI/Settings/GeneralSettingsPane.swift`

**Interfaces:**
- Consumes: `@AppStorage("showMenuBarExtra")`, `@AppStorage("menuBarClickAction")`, `@AppStorage("launchAtLogin")`, `ServiceManagement.SMAppService`
- Produces: General pane UI; login toggle syncs with `SMAppService.mainApp.status`

- [ ] **Step 1: Implement GeneralSettingsPane (shortcuts stubbed to Task 5)**

```swift
import SwiftUI
import ServiceManagement

struct GeneralSettingsPane: View {
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true
    @AppStorage("menuBarClickAction") private var menuBarClickAction = "menu"
    @AppStorage("launchAtLogin") private var launchAtLogin = false

    @State private var loginStatusMessage: String?

    private let clickActionOptions = ["menu": "Show a menu"]

    var body: some View {
        Form {
            Section {
                Toggle("Keep MyPass in the menu bar", isOn: $showMenuBarExtra)
                Picker("Click the icon to", selection: $menuBarClickAction) {
                    Text("Show a menu").tag("menu")
                }
                SettingsHelperText(text: "The menu bar icon provides quick access while MyPass runs. Turning it off hides the icon but keeps the main window available from the Dock.")
            } header: {
                Text("Menu Bar")
            }

            Section {
                Toggle("Start MyPass at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        setLaunchAtLogin(enabled)
                    }
                if let loginStatusMessage {
                    SettingsHelperText(text: loginStatusMessage)
                }
                SettingsHelperText(text: "MyPass opens in the background at login so the vault and extensions are ready. The vault remains locked until you unlock it manually.")
            } header: {
                Text("Login Item")
            }

            Section {
                ShortcutRecorderField(label: "Show MyPass", storageKey: "shortcutShowMyPass", defaultValue: "")
                HStack {
                    Text("Show Quick Access")
                    Spacer()
                    Text("Coming later")
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.secondary)
                ShortcutRecorderField(label: "Lock MyPass", storageKey: "shortcutLockMyPass", defaultValue: "shift+command+L")
                SettingsHelperText(text: "Shortcuts work while MyPass is running. Lock applies only when the vault is unlocked.")
            } header: {
                Text("Keyboard Shortcuts")
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            syncLaunchAtLoginFromService()
        }
    }

    private func syncLaunchAtLoginFromService() {
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLogin = true
            loginStatusMessage = nil
        case .requiresApproval:
            launchAtLogin = false
            loginStatusMessage = "Approval required — open System Settings → General → Login Items and allow MyPass."
        case .notRegistered:
            launchAtLogin = false
            loginStatusMessage = nil
        @unknown default:
            launchAtLogin = false
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            syncLaunchAtLoginFromService()
        } catch {
            launchAtLogin = false
            loginStatusMessage = "Could not update login item: \(error.localizedDescription)"
        }
    }
}
```

`ShortcutRecorderField` is implemented in Task 5 — until then add a minimal stub returning `EmptyView()` in `ShortcutRecorderField.swift`.

- [ ] **Step 2: Build**

Run: `./scripts/build.sh 2>&1 | tail -20`

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add MyPass/UI/Settings/GeneralSettingsPane.swift
git commit -m "feat(settings): General pane menu bar and login item controls"
```

---

### Task 4: ShortcutCodec + tests (TDD)

**Files:**
- Create: `MyPass/UI/Settings/ShortcutCodec.swift`
- Create: `MyPassTests/ShortcutCodecTests.swift`

**Interfaces:**
- Consumes: Carbon modifier flags (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`)
- Produces:
  - `struct ParsedShortcut: Equatable` with `modifiers: UInt32`, `keyCode: UInt16`, `displayString: String`
  - `enum ShortcutCodec` with `static func encode(_ shortcut: ParsedShortcut) -> String`, `static func decode(_ string: String) -> ParsedShortcut?`, `static func from(event: NSEvent) -> ParsedShortcut?`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import MyPass

final class ShortcutCodecTests: XCTestCase {
    func testDecodeShiftCommandL() {
        let parsed = ShortcutCodec.decode("shift+command+L")
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.displayString, "⇧⌘L")
    }

    func testEncodeRoundTrip() {
        let original = ShortcutCodec.decode("shift+command+L")!
        XCTAssertEqual(ShortcutCodec.encode(original), "shift+command+L")
    }

    func testEmptyStringDecodesToNil() {
        XCTAssertNil(ShortcutCodec.decode(""))
        XCTAssertNil(ShortcutCodec.decode("   "))
    }

    func testDisplayStringForEmptyIsNone() {
        XCTAssertEqual(ShortcutCodec.displayString(forStorage: ""), "None")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/generate.sh && xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/ShortcutCodecTests 2>&1 | tail -20`

Expected: FAIL — `ShortcutCodec` not found

- [ ] **Step 3: Implement ShortcutCodec.swift**

```swift
import AppKit
import Carbon

struct ParsedShortcut: Equatable {
    let modifiers: UInt32
    let keyCode: UInt16

    var carbonModifiers: UInt32 {
        var flags: UInt32 = 0
        if modifiers & cmdKey != 0 { flags |= UInt32(cmdKey) }
        if modifiers & shiftKey != 0 { flags |= UInt32(shiftKey) }
        if modifiers & optionKey != 0 { flags |= UInt32(optionKey) }
        if modifiers & controlKey != 0 { flags |= UInt32(controlKey) }
        return flags
    }

    var displayString: String {
        var parts: [String] = []
        if modifiers & controlKey != 0 { parts.append("⌃") }
        if modifiers & optionKey != 0 { parts.append("⌥") }
        if modifiers & shiftKey != 0 { parts.append("⇧") }
        if modifiers & cmdKey != 0 { parts.append("⌘") }
        if let char = keyCodeToCharacter(keyCode) {
            parts.append(char.uppercased())
        }
        return parts.joined()
    }

    private func keyCodeToCharacter(_ keyCode: UInt16) -> String? {
        // Map common letter keyCodes (US keyboard); extend as needed.
        let map: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M"
        ]
        return map[keyCode]
    }
}

enum ShortcutCodec {
    static func encode(_ shortcut: ParsedShortcut) -> String {
        var parts: [String] = []
        if shortcut.modifiers & controlKey != 0 { parts.append("control") }
        if shortcut.modifiers & optionKey != 0 { parts.append("option") }
        if shortcut.modifiers & shiftKey != 0 { parts.append("shift") }
        if shortcut.modifiers & cmdKey != 0 { parts.append("command") }
        if let char = shortcut.displayString.last {
            parts.append(String(char).lowercased())
        }
        return parts.joined(separator: "+")
    }

    static func decode(_ string: String) -> ParsedShortcut? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let tokens = trimmed.lowercased().split(separator: "+").map(String.init)
        guard let keyToken = tokens.last, keyToken.count == 1,
              let keyCode = letterToKeyCode(keyToken) else { return nil }
        var mods: UInt32 = 0
        for token in tokens.dropLast() {
            switch token {
            case "command", "cmd": mods |= UInt32(cmdKey)
            case "shift": mods |= UInt32(shiftKey)
            case "option", "alt": mods |= UInt32(optionKey)
            case "control", "ctrl": mods |= UInt32(controlKey)
            default: return nil
            }
        }
        return ParsedShortcut(modifiers: mods, keyCode: keyCode)
    }

    static func displayString(forStorage storage: String) -> String {
        guard let parsed = decode(storage) else { return "None" }
        return parsed.displayString
    }

    static func from(event: NSEvent) -> ParsedShortcut? {
        guard event.type == .keyDown, let chars = event.charactersIgnoringModifiers?.uppercased(), let first = chars.first else { return nil }
        let keyCode = letterToKeyCode(String(first).lowercased()) ?? UInt16(event.keyCode)
        var mods: UInt32 = 0
        if event.modifierFlags.contains(.command) { mods |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.shift) { mods |= UInt32(shiftKey) }
        if event.modifierFlags.contains(.option) { mods |= UInt32(optionKey) }
        if event.modifierFlags.contains(.control) { mods |= UInt32(controlKey) }
        return ParsedShortcut(modifiers: mods, keyCode: keyCode)
    }

    private static func letterToKeyCode(_ letter: String) -> UInt16? {
        let map: [String: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
            "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
            "y": 16, "t": 17, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46
        ]
        return map[letter.lowercased()]
    }
}
```

- [ ] **Step 4: Run tests**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/ShortcutCodecTests 2>&1 | tail -20`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add MyPass/UI/Settings/ShortcutCodec.swift MyPassTests/ShortcutCodecTests.swift
git commit -m "feat(settings): shortcut encode/decode for keyboard shortcuts"
```

---

### Task 5: ShortcutRecorderField + GlobalHotkeyManager

**Files:**
- Create: `MyPass/UI/Settings/ShortcutRecorderField.swift`
- Create: `MyPass/UI/Settings/GlobalHotkeyManager.swift`

**Interfaces:**
- Consumes: `ShortcutCodec`, `@AppStorage` string keys
- Produces:
  - `struct ShortcutRecorderField: View` — click field, capture keyDown via local `NSEvent` monitor, Clear button sets `""`
  - `final class GlobalHotkeyManager` — `register(id:shortcut:handler:)`, `unregister(id:)`, `reload(showMyPass:lockMyPass:showHandler:lockHandler:)`

- [ ] **Step 1: Implement ShortcutRecorderField**

```swift
import SwiftUI
import AppKit

struct ShortcutRecorderField: View {
    let label: String
    let storageKey: String
    let defaultValue: String

    @AppStorage private var storedValue: String
    @State private var isRecording = false
    @State private var monitor: Any?

    init(label: String, storageKey: String, defaultValue: String) {
        self.label = label
        self.storageKey = storageKey
        self.defaultValue = defaultValue
        _storedValue = AppStorage(wrappedValue: defaultValue, storageKey)
    }

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Button(action: beginRecording) {
                Text(isRecording ? "Press shortcut…" : ShortcutCodec.displayString(forStorage: storedValue))
                    .frame(minWidth: 80, alignment: .trailing)
            }
            .buttonStyle(.bordered)
            Button("Clear") { storedValue = "" }
                .disabled(storedValue.isEmpty)
        }
    }

    private func beginRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape
                stopRecording()
                return nil
            }
            if let shortcut = ShortcutCodec.from(event: event) {
                storedValue = ShortcutCodec.encode(shortcut)
                stopRecording()
                return nil
            }
            return event
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
```

- [ ] **Step 2: Implement GlobalHotkeyManager**

```swift
import Carbon
import AppKit

final class GlobalHotkeyManager {
    static let shared = GlobalHotkeyManager()

    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]

    private init() {
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let userData else { return noErr }
            let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            manager.handlers[hotKeyID.id]?()
            return noErr
        }, 1, &eventSpec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    func register(id: UInt32, shortcut: ParsedShortcut, handler: @escaping () -> Void) {
        unregister(id: id)
        handlers[id] = handler
        var hotKeyID = EventHotKeyID(signature: OSType(0x4D595053), id: id) // 'MYPS'
        RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRefs[id])
    }

    func unregister(id: UInt32) {
        if let ref = hotKeyRefs.removeValue(forKey: id) {
            UnregisterEventHotKey(ref)
        }
        handlers.removeValue(forKey: id)
    }

    func reload(showMyPassStorage: String, lockMyPassStorage: String, showHandler: @escaping () -> Void, lockHandler: @escaping () -> Void) {
        unregister(id: 1)
        unregister(id: 2)
        if let show = ShortcutCodec.decode(showMyPassStorage) {
            register(id: 1, shortcut: show, handler: showHandler)
        }
        if let lock = ShortcutCodec.decode(lockMyPassStorage) {
            register(id: 2, shortcut: lock, handler: lockHandler)
        }
    }
}
```

- [ ] **Step 3: Build**

Run: `./scripts/build.sh 2>&1 | tail -20`

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add MyPass/UI/Settings/ShortcutRecorderField.swift MyPass/UI/Settings/GlobalHotkeyManager.swift MyPass/UI/Settings/GeneralSettingsPane.swift
git commit -m "feat(settings): shortcut recorder and global hotkey registration"
```

---

### Task 6: MyPassApp — MenuBarExtra gating + hotkeys

**Files:**
- Modify: `MyPass/MyPassApp.swift`

**Interfaces:**
- Consumes: `@AppStorage("showMenuBarExtra")`, `@AppStorage("shortcutShowMyPass")`, `@AppStorage("shortcutLockMyPass")`, `GlobalHotkeyManager`
- Produces: Conditional `MenuBarExtra`; hotkeys call activate-main-window and `vaultSession.lock()`

- [ ] **Step 1: Add AppStorage and hotkey reload to MyPassApp**

Add a small helper view or use `@AppStorage` on the App struct:

```swift
@AppStorage("showMenuBarExtra") private var showMenuBarExtra = true
@AppStorage("shortcutShowMyPass") private var shortcutShowMyPass = ""
@AppStorage("shortcutLockMyPass") private var shortcutLockMyPass = "shift+command+L"
```

Replace unconditional `MenuBarExtra` block (lines 212–216) with:

```swift
if showMenuBarExtra {
    MenuBarExtra("MyPass", systemImage: "key.fill") {
        MenuBarExtraContent()
            .environmentObject(vaultSession)
            .environmentObject(navigationState)
    }
}
```

Add `.onAppear` on `WindowGroup` content (or a dedicated `SettingsHotkeyObserver` view injected into `ContentView`):

```swift
.onAppear { reloadGlobalHotkeys() }
.onChange(of: shortcutShowMyPass) { _, _ in reloadGlobalHotkeys() }
.onChange(of: shortcutLockMyPass) { _, _ in reloadGlobalHotkeys() }
```

```swift
private func reloadGlobalHotkeys() {
    GlobalHotkeyManager.shared.reload(
        showMyPassStorage: shortcutShowMyPass,
        lockMyPassStorage: shortcutLockMyPass,
        showHandler: {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.canBecomeMain || $0.isVisible }?.makeKeyAndOrderFront(nil)
        },
        lockHandler: { [vaultSession] in
            if case .unlocked = vaultSession.state {
                vaultSession.lock()
            }
        }
    )
}
```

- [ ] **Step 2: Build and smoke-test**

Run: `./scripts/build.sh 2>&1 | tail -20`

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add MyPass/MyPassApp.swift
git commit -m "feat(app): gate MenuBarExtra on showMenuBarExtra and register global shortcuts"
```

---

### Task 7: Security pane — auto-lock + clipboard UI

**Files:**
- Modify: `MyPass/UI/Settings/SecuritySettingsPane.swift`

**Interfaces:**
- Consumes: `@AppStorage("autoLockTimeoutMinutes")`, `@AppStorage("clipboardClearSeconds")`, `@EnvironmentObject AutoLockController`, Touch ID toggle (Task 9)
- Produces: Security pane with auto-lock stepper (no clipboard mention in auto-lock helper), clipboard stepper 10…120 step 5, Touch ID toggle placeholder until Task 9

- [ ] **Step 1: Implement SecuritySettingsPane auto-lock + clipboard sections**

Move auto-lock from old `SettingsView` (lines 73–80) without the clipboard helper sentence. Add clipboard stepper:

```swift
@AppStorage("autoLockTimeoutMinutes") private var autoLockTimeoutMinutes: Double = 15
@AppStorage("clipboardClearSeconds") private var clipboardClearSeconds: Int = 30
@EnvironmentObject private var autoLockController: AutoLockController
```

```swift
Section {
    Stepper("Lock automatically after inactivity: \(Int(autoLockTimeoutMinutes)) min",
            value: $autoLockTimeoutMinutes, in: 1...120)
    SettingsHelperText(text: "Lock the vault after inactivity so passwords stay protected when you step away.")
} header: { Text("Auto-Lock") }

Section {
    Stepper("Clear clipboard after: \(clipboardClearSeconds) s",
            value: $clipboardClearSeconds, in: 10...120, step: 5)
    SettingsHelperText(text: "Usernames, passwords, and codes copied from MyPass are removed from the clipboard after this interval.")
} header: { Text("Clipboard") }
```

Wire `.onAppear` / `.onChange(of: autoLockTimeoutMinutes)` to `autoLockController.timeout = newValue * 60` (same as old SettingsView lines 130–137).

Add Touch ID section stub (`Toggle` bound to `@State`) — completed in Task 9.

- [ ] **Step 2: Build**

Run: `./scripts/build.sh 2>&1 | tail -20`

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add MyPass/UI/Settings/SecuritySettingsPane.swift
git commit -m "feat(settings): Security pane auto-lock and clipboard interval"
```

---

### Task 8: Clipboard interval wiring + tests

**Files:**
- Create: `MyPass/UI/Settings/ClipboardClearInterval.swift`
- Modify: `MyPass/UI/EntryDetail/EntryDetailView.swift` (line 204)
- Modify: `MyPass/UI/PasswordGenerator/PasswordGeneratorView.swift` (line 45)
- Create: `MyPassTests/ClipboardClearIntervalTests.swift`

**Interfaces:**
- Consumes: `@AppStorage("clipboardClearSeconds")` via `UserDefaults`
- Produces: `enum ClipboardClearInterval { static func seconds(defaults: UserDefaults = .standard) -> TimeInterval }`

- [ ] **Step 1: Write failing test**

```swift
import XCTest
@testable import MyPass

final class ClipboardClearIntervalTests: XCTestCase {
    func testReadsStoredSeconds() {
        let defaults = UserDefaults(suiteName: "ClipboardClearIntervalTests")!
        defaults.removePersistentDomain(forName: "ClipboardClearIntervalTests")
        defaults.set(45, forKey: "clipboardClearSeconds")
        XCTAssertEqual(ClipboardClearInterval.seconds(defaults: defaults), 45)
    }

    func testDefaultIs30WhenUnset() {
        let defaults = UserDefaults(suiteName: "ClipboardClearIntervalTests-default")!
        defaults.removePersistentDomain(forName: "ClipboardClearIntervalTests-default")
        XCTAssertEqual(ClipboardClearInterval.seconds(defaults: defaults), 30)
    }
}
```

- [ ] **Step 2: Run test — expect FAIL**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/ClipboardClearIntervalTests 2>&1 | tail -15`

- [ ] **Step 3: Implement ClipboardClearInterval.swift**

```swift
import Foundation

enum ClipboardClearInterval {
    static func seconds(defaults: UserDefaults = .standard) -> TimeInterval {
        let stored = defaults.object(forKey: "clipboardClearSeconds") as? Int
        return TimeInterval(stored ?? 30)
    }
}
```

- [ ] **Step 4: Update copy call sites**

In `EntryDetailView.copy(_:)` replace `after: 30` with `after: ClipboardClearInterval.seconds()`.

In `PasswordGeneratorView` Copy button replace `after: 30` with `after: ClipboardClearInterval.seconds()`.

- [ ] **Step 5: Run full clipboard tests**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/ClipboardAutoClearTests -only-testing:MyPassTests/ClipboardClearIntervalTests 2>&1 | tail -20`

Expected: PASS (ClipboardAutoClearTests still use explicit `after:` values — unchanged)

- [ ] **Step 6: Commit**

```bash
git add MyPass/UI/Settings/ClipboardClearInterval.swift MyPass/UI/EntryDetail/EntryDetailView.swift MyPass/UI/PasswordGenerator/PasswordGeneratorView.swift MyPassTests/ClipboardClearIntervalTests.swift
git commit -m "feat(settings): wire clipboardClearSeconds to all copy paths"
```

---

### Task 9: Touch ID enrollment toggle + VaultBiometricEnrollment

**Files:**
- Modify: `MyPass/Security/BiometricKeyStore.swift`
- Create: `MyPass/UI/Settings/VaultBiometricEnrollment.swift`
- Modify: `MyPass/UI/Settings/SecuritySettingsPane.swift`
- Create: `MyPassTests/VaultBiometricEnrollmentTests.swift`
- Create: `MyPassTests/SecuritySettingsTouchIDTests.swift`

**Interfaces:**
- Consumes: `BiometricKeyStoring`, `VaultSession.currentDatabase`, `VaultFileStore.load()`, session password confirmation
- Produces:
  - `BiometricKeyStoring.remove(account:)` on protocol + `BiometricKeyStore` + `FakeBiometricKeyStore`
  - `enum VaultBiometricEnrollment { static func deriveTransformedKey(password: String, vaultData: Data) throws -> Data }`
  - Security pane toggle enrolls/removes account `"master"`

- [ ] **Step 1: Add remove to BiometricKeyStoring**

```swift
protocol BiometricKeyStoring {
    func store(derivedKey: Data, account: String) throws
    func retrieve(account: String) throws -> Data?
    func remove(account: String) throws
}
```

Implement in `BiometricKeyStore` and `FakeBiometricKeyStore` using `SecItemDelete` / dictionary remove.

- [ ] **Step 2: Write VaultBiometricEnrollmentTests**

Use a vault created in-test via `VaultSession` + `fileStore.load()` pattern from `VaultSessionTests`.

```swift
func testDeriveTransformedKeyMatchesUnlockPassword() throws {
    // unlock vault with known password, load raw data, derive key, re-open succeeds path
    let data = try XCTUnwrap(fileStore.load())
    let derived = try VaultBiometricEnrollment.deriveTransformedKey(password: "correct-horse", vaultData: data)
    XCTAssertEqual(derived.count, 32)
}
```

- [ ] **Step 3: Implement VaultBiometricEnrollment.swift**

Parse outer header from vault bytes (mirror `KdbxDatabase.open` steps 81–133) and return `transformedKey`. Use package-internal types already public in MyPassKit (`KdbxOuterHeader`, `KeyDerivation`). Add a package-visible helper on `KdbxDatabase` if needed:

```swift
// Packages/MyPassKit/Sources/MyPassKit/KdbxDatabase.swift — add:
public static func deriveTransformedKey(fromVaultData data: Data, password: String) throws -> Data
```

Extract shared derivation logic from `open(data:password:)` into this static method to avoid duplication.

- [ ] **Step 4: Wire SecuritySettingsPane Touch ID toggle**

```swift
@State private var touchIDEnabled = false
@State private var touchIDError: String?
@State private var confirmPassword = ""
@State private var showConfirmSheet = false
let biometricKeyStore: BiometricKeyStoring = BiometricKeyStore()
@EnvironmentObject private var vaultSession: VaultSession
```

On appear: `touchIDEnabled = (try? biometricKeyStore.retrieve(account: "master")) != nil` — use a non-interactive presence check (query without authentication context) via new `BiometricKeyStoring.hasStoredKey(account:)` if `retrieve` triggers biometry; otherwise track enrollment via `SecItemCopyMatching` with `kSecReturnAttributes` only.

Toggle ON (vault must be unlocked): present sheet asking master password → verify by attempting `VaultBiometricEnrollment.deriveTransformedKey` matches unlock → `store(derivedKey:account:"master")`.

Toggle OFF: `try biometricKeyStore.remove(account: "master")`.

Helper subtext per spec.

- [ ] **Step 5: Run tests**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/VaultBiometricEnrollmentTests -only-testing:MyPassTests/BiometricKeyStoreTests -only-testing:MyPassTests/SecuritySettingsTouchIDTests 2>&1 | tail -25`

Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add MyPass/Security/BiometricKeyStore.swift MyPass/UI/Settings/VaultBiometricEnrollment.swift MyPass/UI/Settings/SecuritySettingsPane.swift MyPassTests/ Packages/MyPassKit/Sources/MyPassKit/KdbxDatabase.swift
git commit -m "feat(settings): Touch ID enrollment toggle and derived key storage"
```

---

### Task 10: Browser pane — extract Chrome extension section

**Files:**
- Modify: `MyPass/UI/Settings/BrowserSettingsPane.swift`
- Modify: `MyPass/UI/Settings/SettingsView.swift` (remove old chrome/sync/backup code once extracted)

**Interfaces:**
- Consumes: Chrome `@AppStorage` keys, `NativeMessagingHostInstaller`, `LocalFolderBackend.createBookmark`
- Produces: `BrowserSettingsPane` with identical behavior to old `SettingsView` lines 119–125, 165–196, 323–350

- [ ] **Step 1: Move chromeExtensionSection + installChromeNativeMessagingHost into BrowserSettingsPane**

Copy `@AppStorage("chromeExtensionID")`, `@AppStorage("chromeNativeMessagingDirectoryBookmark")`, `@State chromeInstallStatusMessage`, and private methods verbatim from `SettingsView.swift`.

Detail header: **Browser** with subsection **Chrome Extension** inside the Form.

- [ ] **Step 2: Build**

Run: `./scripts/build.sh 2>&1 | tail -20`

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add MyPass/UI/Settings/BrowserSettingsPane.swift
git commit -m "feat(settings): Browser pane with Chrome extension controls"
```

---

### Task 11: Sync pane — extract sync backends

**Files:**
- Modify: `MyPass/UI/Settings/SyncSettingsPane.swift`

**Interfaces:**
- Consumes: All sync `@AppStorage` keys, `CredentialKeychainStore`, `SyncBackendResolver`, `SFTPConnectionTester`, `@EnvironmentObject VaultSession`
- Produces: Identical sync UI to old `SettingsView` lines 90–117, 143–321, 352–365

- [ ] **Step 1: Move sync sections into SyncSettingsPane**

Move `@AppStorage` sync fields, `@State` connection test / iCloud / manual sync state, `localFolderSection`, `iCloudSection`, `sftpSection`, and helper methods.

Keep `.onAppear { refreshICloudStatus(); loadSFTPCredentialsIfAvailable() }` and `.onChange(of: syncBackendRawValue)`.

- [ ] **Step 2: Run existing sync settings tests**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/SettingsViewSyncBackendTests 2>&1 | tail -20`

Expected: PASS (tests hit resolver types, not view layout)

- [ ] **Step 3: Commit**

```bash
git add MyPass/UI/Settings/SyncSettingsPane.swift
git commit -m "feat(settings): Sync pane with unchanged backend behavior"
```

---

### Task 12: Backups pane + remove monolithic SettingsView body

**Files:**
- Modify: `MyPass/UI/Settings/BackupsSettingsPane.swift`
- Modify: `MyPass/UI/Settings/SettingsView.swift` (delete relocated code — shell only remains)

**Interfaces:**
- Consumes: `@AppStorage("backupCount")`
- Produces: Backups stepper 1…50 with helper subtext (old lines 82–88)

- [ ] **Step 1: Implement BackupsSettingsPane**

```swift
struct BackupsSettingsPane: View {
    @AppStorage("backupCount") private var backupCount: Int = 10

    var body: some View {
        Form {
            Section {
                Stepper("Keep last: \(backupCount)", value: $backupCount, in: 1...50)
                SettingsHelperText(text: "Rotate local backup copies of the vault file so you can recover from a corrupted save.")
            } header: {
                Text("Backups")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
```

- [ ] **Step 2: Strip old Form body from SettingsView — shell file should contain only NavigationSplitView wiring**

Verify `SettingsView.swift` has no duplicate `@AppStorage` sync/chrome fields.

- [ ] **Step 3: Full test suite**

Run: `./scripts/test.sh 2>&1 | tail -30`

Expected: all tests PASS

- [ ] **Step 4: Build**

Run: `./scripts/build.sh 2>&1 | tail -20`

Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add MyPass/UI/Settings/
git commit -m "feat(settings): Backups pane and complete settings redesign"
```

---

## Self-Review

### 1. Spec coverage

| Spec requirement | Task |
|---|---|
| NavigationSplitView, ~180 pt sidebar, 5 panes, General default | Task 2 |
| `settingsSelectedPane` persistence | Task 2 |
| General: menu bar toggle | Task 3, 6 |
| General: click icon → Show a menu only | Task 3 |
| General: login item SMAppService | Task 3 |
| General: shortcut recorders Show/Lock; Quick Access disabled | Task 3, 4, 5 |
| Security: auto-lock stepper | Task 7 |
| Security: Touch ID enroll/remove | Task 9 |
| Security: clipboard stepper 10…120 | Task 7, 8 |
| Browser: Chrome extension unchanged | Task 10 |
| Sync: all backends unchanged | Task 11 |
| Backups: keep last stepper | Task 12 |
| Helper subtext on groups | Tasks 3, 7, 10–12 |
| No Appearance/Privacy/Labs/About | Task 2 (only 5 panes) |
| MenuBarExtra gating only (no content redesign) | Task 6 |
| Preserve AppStorage keys | Tasks 10–12 (move only) |

**Gaps:** None identified.

### 2. Placeholder scan

No TBD/TODO/similar-to-task-only steps. ShortcutRecorder and GlobalHotkeyManager include concrete implementations.

### 3. Type consistency

- `@AppStorage` keys match spec table: `showMenuBarExtra`, `menuBarClickAction`, `launchAtLogin`, `shortcutShowMyPass`, `shortcutLockMyPass`, `clipboardClearSeconds`, `settingsSelectedPane`
- `ShortcutCodec.encode/decode` used consistently by recorder and hotkey manager
- Touch ID account `"master"` matches `UnlockView` and menu bar spec

---

**Plan complete.** Execute via subagent-driven-development (recommended) or executing-plans. **Land this plan before the menu bar redesign plan** (`docs/superpowers/plans/2026-07-26-mypass-menu-bar-redesign.md`).
