# MyPass Phase 7 (Localization): Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Localize the macOS app (String Catalog + Settings language override) and Chrome extension (`_locales` + `chrome.i18n`) for **en**, **uk**, and **de**, per `docs/superpowers/specs/2026-07-26-mypass-phase7-localization-design.md`.

**Architecture:** English is the source locale in all catalogs. macOS UI strings migrate from hard-coded literals to semantic keys in `MyPass/Localizable.xcstrings`, accessed via `String(localized:)`. A persisted `AppLanguage` preference (System / en / uk / de) drives SwiftUI's `\.locale` environment at launch. Chrome uses standard MV3 `_locales/{en,uk,de}/messages.json` and follows the **browser UI locale** (not the app Settings override in v1). Vault content (group names, entry titles) is never translated; the Recycle Bin **stored** group name stays `"Recycle Bin"` while the sidebar **label** is localized.

**Tech Stack:** Swift 5.10, SwiftUI (macOS 14+), String Catalog (`.xcstrings`), XcodeGen (`project.yml`), XCTest, Chrome Manifest V3 + `chrome.i18n`, Node.js (extension unit tests).

## Global Constraints

- English is the source locale in all localization catalogs (`Localizable.xcstrings`, Chrome `_locales`).
- Locales v1: **en**, **uk**, **de**.
- macOS: `Localizable.xcstrings` + `String(localized:)`; Settings language override (System / English / Українська / Deutsch).
- Chrome: `_locales` + `chrome.i18n`; follows **browser UI locale** (NOT app Settings) in v1.
- Vault content is **not** translated; Recycle Bin **stored** name stays `"Recycle Bin"` (`GroupTreeOperations.recycleBinGroupName`); UI label is localized separately.
- Root **`RUN.md` stays Ukrainian** — add a Ukrainian testing section only; do not translate RUN.md to English.
- macOS 14+, Swift 5.10, XcodeGen; run `./scripts/generate.sh` before build/test.
- No automated translation CI in this phase.
- Migrate `SyncBackendOption` UserDefaults from display strings (`"Local File"`, etc.) to stable codes (`local`, `icloud`, `sftp`) **before** localizing the Settings sync picker.
- Semantic string keys (e.g. `settings.language.title`), not English-as-key.
- No placeholders — every step below contains real code, paths, and translations.

---

### Task 1: Stable SyncBackendOption codes

**Files:**
- Modify: `MyPass/UI/Settings/SettingsView.swift` (move enum + add migration helper)
- Create: `MyPass/State/SyncBackendOption.swift`
- Modify: `MyPass/MyPassApp.swift` (import/use migrated resolver)
- Test: `MyPassTests/SyncBackendOptionTests.swift`

**Interfaces:**
- Consumes: existing `@AppStorage("syncBackend")` key and `UserDefaultsSyncCheckpointStore` keyed by backend.
- Produces:
```swift
enum SyncBackendOption: String, CaseIterable, Identifiable {
    case local = "local"
    case iCloud = "icloud"
    case sftp = "sftp"
    var id: String { rawValue }
    var isAvailable: Bool { true }
    var displayName: String { String(localized: String.LocalizationValue(localizationKey)) }
    private var localizationKey: String { ... }
}

enum SyncBackendOptionMigration {
    static func resolveStoredRawValue(from defaults: UserDefaults = .standard) -> String
    static func migrateIfNeeded(defaults: UserDefaults = .standard)
}
```

- [ ] **Step 1: Write the failing test**

Create `MyPassTests/SyncBackendOptionTests.swift`:

```swift
import XCTest
@testable import MyPass

final class SyncBackendOptionTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suiteName = "SyncBackendOptionTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testStableRawValuesAreCodesNotDisplayNames() {
        XCTAssertEqual(SyncBackendOption.local.rawValue, "local")
        XCTAssertEqual(SyncBackendOption.iCloud.rawValue, "icloud")
        XCTAssertEqual(SyncBackendOption.sftp.rawValue, "sftp")
    }

    func testMigrateLegacyLocalFileDisplayString() {
        defaults.set("Local File", forKey: "syncBackend")
        SyncBackendOptionMigration.migrateIfNeeded(defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: "syncBackend"), "local")
    }

    func testMigrateLegacyICloudDriveDisplayString() {
        defaults.set("iCloud Drive", forKey: "syncBackend")
        SyncBackendOptionMigration.migrateIfNeeded(defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: "syncBackend"), "icloud")
    }

    func testMigrateLegacySFTPDisplayString() {
        defaults.set("SFTP", forKey: "syncBackend")
        SyncBackendOptionMigration.migrateIfNeeded(defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: "syncBackend"), "sftp")
    }

    func testResolveStoredRawValueLeavesStableCodesUntouched() {
        defaults.set("sftp", forKey: "syncBackend")
        SyncBackendOptionMigration.migrateIfNeeded(defaults: defaults)
        XCTAssertEqual(SyncBackendOptionMigration.resolveStoredRawValue(defaults: defaults), "sftp")
    }

    func testResolveStoredRawValueDefaultsToLocalWhenMissing() {
        XCTAssertEqual(SyncBackendOptionMigration.resolveStoredRawValue(defaults: defaults), SyncBackendOption.local.rawValue)
    }

    func testOptionFromResolvedRawValue() {
        defaults.set("iCloud Drive", forKey: "syncBackend")
        let raw = SyncBackendOptionMigration.resolveStoredRawValue(defaults: defaults)
        XCTAssertEqual(SyncBackendOption(rawValue: raw), .iCloud)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/generate.sh && xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/SyncBackendOptionTests`
Expected: FAIL — `SyncBackendOptionMigration` / moved enum not found.

- [ ] **Step 3: Write minimal implementation**

Create `MyPass/State/SyncBackendOption.swift`:

```swift
import Foundation

enum SyncBackendOption: String, CaseIterable, Identifiable {
    case local = "local"
    case iCloud = "icloud"
    case sftp = "sftp"

    var id: String { rawValue }

    var isAvailable: Bool { true }

    /// Localized picker label — keys land in `Localizable.xcstrings` in Task 6.
    /// Until then, English fallbacks keep Settings readable.
    var displayName: String {
        switch self {
        case .local: return String(localized: "settings.syncBackend.local", defaultValue: "Local File")
        case .iCloud: return String(localized: "settings.syncBackend.icloud", defaultValue: "iCloud Drive")
        case .sftp: return String(localized: "settings.syncBackend.sftp", defaultValue: "SFTP")
        }
    }
}

enum SyncBackendOptionMigration {
    private static let storageKey = "syncBackend"

    private static let legacyDisplayToCode: [String: String] = [
        "Local File": SyncBackendOption.local.rawValue,
        "iCloud Drive": SyncBackendOption.iCloud.rawValue,
        "SFTP": SyncBackendOption.sftp.rawValue,
    ]

    static func migrateIfNeeded(defaults: UserDefaults = .standard) {
        guard let stored = defaults.string(forKey: storageKey),
              let migrated = legacyDisplayToCode[stored] else { return }
        defaults.set(migrated, forKey: storageKey)
    }

    static func resolveStoredRawValue(defaults: UserDefaults = .standard) -> String {
        migrateIfNeeded(defaults: defaults)
        return defaults.string(forKey: storageKey) ?? SyncBackendOption.local.rawValue
    }
}
```

Remove the `enum SyncBackendOption` block from `MyPass/UI/Settings/SettingsView.swift` (lines 6–14). Update the picker to tag stable codes and show localized labels:

```swift
Picker("Backend", selection: $syncBackendRawValue) {
    ForEach(SyncBackendOption.allCases) { option in
        Text(option.displayName).tag(option.rawValue)
    }
}
```

Change the default `@AppStorage` initializer:

```swift
@AppStorage("syncBackend") private var syncBackendRawValue: String = SyncBackendOption.local.rawValue
```

In `MyPass/MyPassApp.swift`, replace:

```swift
let syncBackendOption = SyncBackendOption(rawValue: defaults.string(forKey: "syncBackend") ?? "") ?? .local
```

with:

```swift
let syncBackendRaw = SyncBackendOptionMigration.resolveStoredRawValue(defaults: defaults)
let syncBackendOption = SyncBackendOption(rawValue: syncBackendRaw) ?? .local
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/generate.sh && xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/SyncBackendOptionTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add MyPass/State/SyncBackendOption.swift MyPass/UI/Settings/SettingsView.swift MyPass/MyPassApp.swift MyPassTests/SyncBackendOptionTests.swift
git commit -m "refactor: migrate SyncBackendOption UserDefaults to stable codes"
```

---

### Task 2: AppLanguage preference model + unit tests

**Files:**
- Create: `MyPass/Localization/AppLanguage.swift`
- Test: `MyPassTests/AppLanguageTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
```swift
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, uk, de
    static let userDefaultsKey = "appLanguage"
    static var current: AppLanguage
    var locale: Locale
    var pickerLabel: String  // native script; hardcoded OK per spec
}
```

- [ ] **Step 1: Write the failing test**

Create `MyPassTests/AppLanguageTests.swift`:

```swift
import XCTest
@testable import MyPass

final class AppLanguageTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suiteName = "AppLanguageTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDefaultIsSystemWhenUnset() {
        XCTAssertEqual(AppLanguage.resolved(defaults: defaults), .system)
    }

    func testPersistsExplicitChoice() {
        AppLanguage.en.save(defaults: defaults)
        XCTAssertEqual(AppLanguage.resolved(defaults: defaults), .en)
    }

    func testSystemLocaleUsesAutoupdatingCurrent() {
        let locale = AppLanguage.system.locale
        XCTAssertEqual(locale, Locale.autoupdatingCurrent)
    }

    func testEnglishLocaleIdentifier() {
        XCTAssertEqual(AppLanguage.en.locale.identifier, "en")
    }

    func testUkrainianLocaleIdentifier() {
        XCTAssertEqual(AppLanguage.uk.locale.identifier, "uk")
    }

    func testGermanLocaleIdentifier() {
        XCTAssertEqual(AppLanguage.de.locale.identifier, "de")
    }

    func testRawValuesRoundTrip() {
        for language in AppLanguage.allCases {
            XCTAssertEqual(AppLanguage(rawValue: language.rawValue), language)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/generate.sh && xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/AppLanguageTests`
Expected: FAIL — `AppLanguage` not found.

- [ ] **Step 3: Write minimal implementation**

Create `MyPass/Localization/AppLanguage.swift`:

```swift
import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case en
    case uk
    case de

    static let userDefaultsKey = "appLanguage"

    var id: String { rawValue }

    /// Shown in the Settings language picker — native names, intentionally not catalog-driven.
    var pickerLabel: String {
        switch self {
        case .system: return "System"
        case .en: return "English"
        case .uk: return "Українська"
        case .de: return "Deutsch"
        }
    }

    var locale: Locale {
        switch self {
        case .system:
            return Locale.autoupdatingCurrent
        case .en:
            return Locale(identifier: "en")
        case .uk:
            return Locale(identifier: "uk")
        case .de:
            return Locale(identifier: "de")
        }
    }

    static func resolved(defaults: UserDefaults = .standard) -> AppLanguage {
        guard let raw = defaults.string(forKey: userDefaultsKey),
              let language = AppLanguage(rawValue: raw) else {
            return .system
        }
        return language
    }

    static var current: AppLanguage {
        resolved()
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.userDefaultsKey)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/generate.sh && xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/AppLanguageTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add MyPass/Localization/AppLanguage.swift MyPassTests/AppLanguageTests.swift
git commit -m "feat: add AppLanguage preference model with locale resolution"
```

---

### Task 3: Apply language at launch + Settings Language picker

**Files:**
- Create: `MyPass/Localization/LanguagePreferences.swift`
- Modify: `MyPass/MyPassApp.swift`
- Modify: `MyPass/AppDelegate.swift`
- Modify: `MyPass/UI/Settings/SettingsView.swift`

**Interfaces:**
- Consumes: `AppLanguage` from Task 2.
- Produces:
```swift
@MainActor
enum LanguagePreferences {
    static func applyEarly(defaults: UserDefaults = .standard)
    static func localeEnvironmentValue(defaults: UserDefaults = .standard) -> Locale
}
```

- [ ] **Step 1: Create LanguagePreferences helper**

Create `MyPass/Localization/LanguagePreferences.swift`:

```swift
import Foundation

@MainActor
enum LanguagePreferences {
    /// Call as early as possible (AppDelegate / MyPassApp.init) so String Catalog
    /// lookups and SwiftUI environment agree before first frame.
    static func applyEarly(defaults: UserDefaults = .standard) {
        let language = AppLanguage.resolved(defaults: defaults)
        guard language != .system else { return }
        UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
    }

    static func localeEnvironmentValue(defaults: UserDefaults = .standard) -> Locale {
        AppLanguage.resolved(defaults: defaults).locale
    }
}
```

- [ ] **Step 2: Wire AppDelegate early apply**

Modify `MyPass/AppDelegate.swift` — add:

```swift
func applicationWillFinishLaunching(_ notification: Notification) {
    LanguagePreferences.applyEarly()
}
```

- [ ] **Step 3: Apply `\.locale` to all SwiftUI scenes**

Modify `MyPass/MyPassApp.swift` — add a stored locale and environment modifier:

```swift
@main
struct MyPassApp: App {
    // ... existing properties ...
    private let appLocale: Locale

    init() {
        LanguagePreferences.applyEarly()
        appLocale = LanguagePreferences.localeEnvironmentValue()
        // ... rest of existing init() unchanged ...
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vaultSession)
                .environmentObject(navigationState)
                .environmentObject(autoLockController)
                .environment(\.locale, appLocale)
        }

        MenuBarExtra("MyPass", systemImage: "key.fill") {
            MenuBarExtraContent()
                .environmentObject(vaultSession)
                .environmentObject(navigationState)
                .environment(\.locale, appLocale)
        }

        Settings {
            SettingsView()
                .environmentObject(autoLockController)
                .environmentObject(vaultSession)
                .environment(\.locale, appLocale)
        }
    }
}
```

Add `@AppStorage` language binding to `SettingsView` (top of struct, after existing `@AppStorage` lines):

```swift
@AppStorage(AppLanguage.userDefaultsKey) private var appLanguageRawValue: String = AppLanguage.system.rawValue
```

Add a Language section at the **top** of the Form body (before Auto-Lock):

```swift
Section("Language") {
    Picker("Language", selection: $appLanguageRawValue) {
        ForEach(AppLanguage.allCases) { language in
            Text(language.pickerLabel).tag(language.rawValue)
        }
    }
    .onChange(of: appLanguageRawValue) { _, newValue in
        if let language = AppLanguage(rawValue: newValue) {
            language.save()
            LanguagePreferences.applyEarly()
        }
    }
    Text("Changing language takes effect after restarting MyPass.")
        .font(.caption)
        .foregroundStyle(.secondary)
}
```

> **Note:** Full catalog localization of Settings section titles arrives in Task 6. The picker labels above stay hardcoded in native script per the design spec. Restart prompt uses English until Task 6 adds `settings.language.restartHint` to the catalog.

- [ ] **Step 4: Manual smoke test**

Run: `./scripts/run.sh`
Expected:
- Settings → Language shows System / English / Українська / Deutsch.
- Choosing **Deutsch**, restarting the app, then unlocking — UI strings still English until Task 4+ (catalog not wired yet), but `Locale.current.identifier` reflects `de` once catalogs land.

- [ ] **Step 5: Commit**

```bash
git add MyPass/Localization/LanguagePreferences.swift MyPass/AppDelegate.swift MyPass/MyPassApp.swift MyPass/UI/Settings/SettingsView.swift
git commit -m "feat: apply AppLanguage at launch and add Settings language picker"
```

---

### Task 4: Create Localizable.xcstrings scaffold + migrate UnlockView, ContentView, MenuBar

**Files:**
- Create: `MyPass/Localizable.xcstrings`
- Modify: `MyPass/UI/Unlock/UnlockView.swift`
- Modify: `MyPass/ContentView.swift`
- Modify: `MyPass/UI/MenuBar/MenuBarExtraContent.swift`
- Modify: `MyPass/MyPassApp.swift` (MenuBarExtra title)
- Modify: `project.yml` (ensure catalog is bundled)

**Interfaces:**
- Consumes: `AppLanguage` locale environment from Task 3.
- Produces: `MyPass/Localizable.xcstrings` with keys for this slice; pattern for all later tasks.

- [ ] **Step 1: Create String Catalog scaffold**

Create `MyPass/Localizable.xcstrings`:

```json
{
  "sourceLanguage" : "en",
  "strings" : {
    "content.saveError.title" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Speicherfehler" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Save Error" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Помилка збереження" } }
      }
    },
    "menubar.appName" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "MyPass" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "MyPass" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "MyPass" } }
      }
    },
    "menubar.lock" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Sperren" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Lock" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Заблокувати" } }
      }
    },
    "menubar.locked" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Gesperrt" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Locked" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Заблоковано" } }
      }
    },
    "menubar.passwordGenerator" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Passwortgenerator" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Password Generator" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Генератор паролів" } }
      }
    },
    "menubar.quickSearch" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Schnellsuche" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Quick Search" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Швидкий пошук" } }
      }
    },
    "menubar.unlocked" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Entsperrt" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Unlocked" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Розблоковано" } }
      }
    },
    "unlock.button" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Entsperren" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Unlock" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Розблокувати" } }
      }
    },
    "unlock.error.incorrectPassword" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Falsches Passwort oder beschädigte Datei." } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Incorrect password or corrupted file." } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Невірний пароль або пошкоджений файл." } }
      }
    },
    "unlock.error.touchIDUnavailable" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Touch ID ist nicht verfügbar." } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Touch ID is unavailable." } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Touch ID недоступний." } }
      }
    },
    "unlock.masterPassword" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Hauptpasswort" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Master Password" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Головний пароль" } }
      }
    },
    "unlock.title" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "MyPass" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "MyPass" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "MyPass" } }
      }
    },
    "unlock.touchID" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Touch ID" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Touch ID" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Touch ID" } }
      }
    }
  },
  "version" : "1.0"
}
```

Ensure `project.yml` includes the catalog (XcodeGen picks up `MyPass/**` sources; add explicit resource if needed):

```yaml
    sources:
      - path: MyPass
        excludes:
          - "**/*.entitlements"
```

No change required if `Localizable.xcstrings` lives under `MyPass/` — XcodeGen treats `.xcstrings` as a localized resource automatically.

- [ ] **Step 2: Migrate UnlockView**

Replace hard-coded strings in `MyPass/UI/Unlock/UnlockView.swift`:

```swift
Text("MyPass")
```
→
```swift
Text(String(localized: "unlock.title"))
```

```swift
SecureField("Master Password", text: $password)
```
→
```swift
SecureField(String(localized: "unlock.masterPassword"), text: $password)
```

```swift
Button("Unlock", action: attemptUnlock)
```
→
```swift
Button(String(localized: "unlock.button"), action: attemptUnlock)
```

```swift
Button("Touch ID", systemImage: "touchid", action: attemptBiometricUnlock)
```
→
```swift
Button(String(localized: "unlock.touchID"), systemImage: "touchid", action: attemptBiometricUnlock)
```

```swift
errorMessage = "Incorrect password or corrupted file."
```
→
```swift
errorMessage = String(localized: "unlock.error.incorrectPassword")
```

```swift
? "Touch ID is unavailable."
```
→
```swift
? String(localized: "unlock.error.touchIDUnavailable")
```

- [ ] **Step 3: Migrate ContentView alert title**

In `MyPass/ContentView.swift`:

```swift
.alert(
    "Save Error",
```
→
```swift
.alert(
    String(localized: "content.saveError.title"),
```

- [ ] **Step 4: Migrate MenuBarExtraContent + MenuBarExtra title**

In `MyPass/UI/MenuBar/MenuBarExtraContent.swift`:

```swift
case .locked: return "Locked"
case .unlocked: return "Unlocked"
```
→
```swift
case .locked: return String(localized: "menubar.locked")
case .unlocked: return String(localized: "menubar.unlocked")
```

```swift
TextField("Quick Search", text: $navigationState.searchText)
```
→
```swift
TextField(String(localized: "menubar.quickSearch"), text: $navigationState.searchText)
```

```swift
Button("Lock") {
```
→
```swift
Button(String(localized: "menubar.lock")) {
```

```swift
Button("Password Generator") {
```
→
```swift
Button(String(localized: "menubar.passwordGenerator")) {
```

In `MyPass/MyPassApp.swift`:

```swift
MenuBarExtra("MyPass", systemImage: "key.fill") {
```
→
```swift
MenuBarExtra(String(localized: "menubar.appName"), systemImage: "key.fill") {
```

- [ ] **Step 5: Build and manual verify**

Run: `./scripts/build.sh && ./scripts/run.sh`
Expected with Settings → Language → **Українська** + app restart:
- Unlock screen shows **Розблокувати**, **Головний пароль**.
- Menu bar extra shows **Заблоковано** / **Розблоковано**, **Швидкий пошук**.

- [ ] **Step 6: Commit**

```bash
git add MyPass/Localizable.xcstrings MyPass/UI/Unlock/UnlockView.swift MyPass/ContentView.swift MyPass/UI/MenuBar/MenuBarExtraContent.swift MyPass/MyPassApp.swift
git commit -m "feat: add String Catalog and localize unlock, content alert, menu bar"
```

---

### Task 5: Migrate EntryDetail, EntryEdit, History, EntryList, PasswordGenerator, GroupSidebar

**Files:**
- Modify: `MyPass/Localizable.xcstrings` (add keys below)
- Modify: `MyPass/UI/EntryDetail/EntryDetailView.swift`
- Modify: `MyPass/UI/EntryDetail/EntryEditView.swift`
- Modify: `MyPass/UI/EntryDetail/HistoryView.swift`
- Modify: `MyPass/UI/EntryList/EntryListView.swift`
- Modify: `MyPass/UI/PasswordGenerator/PasswordGeneratorView.swift`
- Modify: `MyPass/UI/Sidebar/GroupSidebarView.swift`

**Interfaces:**
- Consumes: `Localizable.xcstrings` from Task 4; `GroupTreeOperations.recycleBinGroupName` stays `"Recycle Bin"` for vault storage.
- Produces: localized display for recycle bin sidebar via `sidebar.recycleBin` key only.

- [ ] **Step 1: Append catalog entries**

Merge into `MyPass/Localizable.xcstrings` `"strings"` object:

```json
    "common.copy" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Kopieren" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Copy" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Копіювати" } }
      }
    },
    "common.untitled" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "(ohne Titel)" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "(untitled)" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "(без назви)" } }
      }
    },
    "entryDetail.delete" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Löschen" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Delete" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Видалити" } }
      }
    },
    "entryDetail.edit" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Bearbeiten" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Edit" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Редагувати" } }
      }
    },
    "entryDetail.field.notes" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Notizen" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Notes" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Нотатки" } }
      }
    },
    "entryDetail.field.password" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Passwort" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Password" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Пароль" } }
      }
    },
    "entryDetail.field.title" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Titel" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Title" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Назва" } }
      }
    },
    "entryDetail.field.url" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "URL" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "URL" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "URL" } }
      }
    },
    "entryDetail.field.username" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Benutzername" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Username" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Ім'я користувача" } }
      }
    },
    "entryDetail.hide" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Ausblenden" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Hide" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Приховати" } }
      }
    },
    "entryDetail.history" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Verlauf" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "History" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Історія" } }
      }
    },
    "entryDetail.open" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Öffnen" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Open" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Відкрити" } }
      }
    },
    "entryDetail.restore" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Wiederherstellen" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Restore" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Відновити" } }
      }
    },
    "entryDetail.selectEntry" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Eintrag auswählen" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Select an entry" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Оберіть запис" } }
      }
    },
    "entryDetail.show" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Anzeigen" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Show" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Показати" } }
      }
    },
    "entryDetail.totp" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "TOTP: %@" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "TOTP: %@" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "TOTP: %@" } }
      }
    },
    "entryDetail.totpRemaining" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "(%lld s)" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "(%llds)" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "(%lld с)" } }
      }
    },
    "entryEdit.addField" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Feld hinzufügen" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Add Field" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Додати поле" } }
      }
    },
    "entryEdit.additionalFields" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Zusätzliche Felder" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Additional Fields" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Додаткові поля" } }
      }
    },
    "entryEdit.cancel" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Abbrechen" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Cancel" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Скасувати" } }
      }
    },
    "entryEdit.field.key" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Schlüssel" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Key" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Ключ" } }
      }
    },
    "entryEdit.field.notes" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Notizen" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Notes" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Нотатки" } }
      }
    },
    "entryEdit.field.password" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Passwort" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Password" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Пароль" } }
      }
    },
    "entryEdit.field.title" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Titel" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Title" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Назва" } }
      }
    },
    "entryEdit.field.url" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "URL" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "URL" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "URL" } }
      }
    },
    "entryEdit.field.username" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Benutzername" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Username" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Ім'я користувача" } }
      }
    },
    "entryEdit.field.value" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Wert" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Value" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Значення" } }
      }
    },
    "entryEdit.generate" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Generieren" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Generate" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Згенерувати" } }
      }
    },
    "entryEdit.otpPlaceholder" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "otpauth:// oder Geheimnis" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "otpauth:// or secret" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "otpauth:// або секрет" } }
      }
    },
    "entryEdit.remove" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Entfernen" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Remove" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Прибрати" } }
      }
    },
    "entryEdit.save" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Speichern" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Save" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Зберегти" } }
      }
    },
    "entryList.add" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Hinzufügen" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Add" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Додати" } }
      }
    },
    "entryList.import" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Importieren" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Import" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Імпорт" } }
      }
    },
    "entryList.importCSV" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "CSV importieren…" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Import CSV…" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Імпорт CSV…" } }
      }
    },
    "entryList.openKdbx" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Vorhandene .kdbx öffnen…" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Open Existing .kdbx…" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Відкрити наявний .kdbx…" } }
      }
    },
    "history.restoreVersion" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Diese Version wiederherstellen" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Restore This Version" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Відновити цю версію" } }
      }
    },
    "passwordGen.digits" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Ziffern" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Digits" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Цифри" } }
      }
    },
    "passwordGen.error.failed" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Passwort konnte nicht generiert werden." } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Failed to generate password." } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Не вдалося згенерувати пароль." } }
      }
    },
    "passwordGen.error.noClass" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Wählen Sie mindestens eine Zeichenklasse." } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Select at least one character class." } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Оберіть щонайменше один клас символів." } }
      }
    },
    "passwordGen.generate" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Generieren" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Generate" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Згенерувати" } }
      }
    },
    "passwordGen.length" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Länge: %lld" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Length: %lld" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Довжина: %lld" } }
      }
    },
    "passwordGen.lowercase" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Kleinbuchstaben" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Lowercase" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Малі літери" } }
      }
    },
    "passwordGen.symbols" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Symbole" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Symbols" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Символи" } }
      }
    },
    "passwordGen.uppercase" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Großbuchstaben" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Uppercase" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Великі літери" } }
      }
    },
    "passwordGen.use" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Verwenden" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Use" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Використати" } }
      }
    },
    "sidebar.deleteGroup" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Gruppe löschen" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Delete Group" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Видалити групу" } }
      }
    },
    "sidebar.newSubgroup" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Neue Untergruppe" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "New Subgroup" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Нова підгрупа" } }
      }
    },
    "sidebar.recycleBin" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Papierkorb" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Recycle Bin" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Кошик" } }
      }
    }
```

- [ ] **Step 2: Migrate EntryDetailView**

Key replacements in `MyPass/UI/EntryDetail/EntryDetailView.swift`:

```swift
LabeledContent("Title", value: entry.title)
→ LabeledContent(String(localized: "entryDetail.field.title"), value: entry.title)

LabeledContent("Username", value: entry.login)
→ LabeledContent(String(localized: "entryDetail.field.username"), value: entry.login)

Button("Copy", ...) → Button(String(localized: "common.copy"), ...)

LabeledContent("Password", ...)
→ LabeledContent(String(localized: "entryDetail.field.password"), ...)

Button(isPasswordRevealed ? "Hide" : "Show")
→ Button(isPasswordRevealed ? String(localized: "entryDetail.hide") : String(localized: "entryDetail.show"))

LabeledContent("URL", ...) → LabeledContent(String(localized: "entryDetail.field.url"), ...)
LabeledContent("Notes", ...) → LabeledContent(String(localized: "entryDetail.field.notes"), ...)

Text("TOTP: \(code)") → Text(String(format: String(localized: "entryDetail.totp"), code))
Text("(\(Int(remaining))s)") → Text(String(format: String(localized: "entryDetail.totpRemaining"), Int64(remaining)))

Button("Open") → Button(String(localized: "entryDetail.open"))
Button("History") → Button(String(localized: "entryDetail.history"))
Button("Edit") → Button(String(localized: "entryDetail.edit"))
Button("Restore") → Button(String(localized: "entryDetail.restore"))
Button("Delete", role: .destructive) → Button(String(localized: "entryDetail.delete"), role: .destructive)

Text("Select an entry") → Text(String(localized: "entryDetail.selectEntry"))
```

- [ ] **Step 3: Migrate EntryEditView**

```swift
TextField("Title", ...) → TextField(String(localized: "entryEdit.field.title"), ...)
TextField("Username", ...) → TextField(String(localized: "entryEdit.field.username"), ...)
SecureField("Password", ...) → SecureField(String(localized: "entryEdit.field.password"), ...)
Button("Generate") → Button(String(localized: "entryEdit.generate"))
TextField("URL", ...) → TextField(String(localized: "entryEdit.field.url"), ...)
TextField("Notes", ...) → TextField(String(localized: "entryEdit.field.notes"), ...)
TextField("otpauth:// or secret", ...) → TextField(String(localized: "entryEdit.otpPlaceholder"), ...)
Section("Additional Fields") → Section(String(localized: "entryEdit.additionalFields"))
TextField("Key", ...) → TextField(String(localized: "entryEdit.field.key"), ...)
TextField("Value", ...) → TextField(String(localized: "entryEdit.field.value"), ...)
Button("Remove", ...) → Button(String(localized: "entryEdit.remove"), ...)
Button("Add Field", ...) → Button(String(localized: "entryEdit.addField"), ...)
Button("Cancel") → Button(String(localized: "entryEdit.cancel"))
Button("Save", ...) → Button(String(localized: "entryEdit.save"), ...)
```

- [ ] **Step 4: Migrate HistoryView, EntryListView, PasswordGeneratorView**

`HistoryView.swift`:
```swift
Text(version.title.isEmpty ? "(untitled)" : version.title)
→ Text(version.title.isEmpty ? String(localized: "common.untitled") : version.title)

Button("Restore This Version") → Button(String(localized: "history.restoreVersion"))
```

`EntryListView.swift`:
```swift
Text(entry.title.isEmpty ? "(untitled)" : entry.title)
→ Text(entry.title.isEmpty ? String(localized: "common.untitled") : entry.title)

Button("Add", ...) → Button(String(localized: "entryList.add"), ...)
Menu("Import", ...) → Menu(String(localized: "entryList.import"), ...)
Button("Import CSV…") → Button(String(localized: "entryList.importCSV"))
Button("Open Existing .kdbx…") → Button(String(localized: "entryList.openKdbx"))
```

`PasswordGeneratorView.swift`:
```swift
Text("Length: \(Int(length))") → Text(String(format: String(localized: "passwordGen.length"), Int64(length)))
Toggle("Lowercase", ...) → Toggle(String(localized: "passwordGen.lowercase"), ...)
Toggle("Uppercase", ...) → Toggle(String(localized: "passwordGen.uppercase"), ...)
Toggle("Digits", ...) → Toggle(String(localized: "passwordGen.digits"), ...)
Toggle("Symbols", ...) → Toggle(String(localized: "passwordGen.symbols"), ...)
Button("Generate", ...) → Button(String(localized: "passwordGen.generate"), ...)
errorMessage = "Select at least one character class." → String(localized: "passwordGen.error.noClass")
errorMessage = "Failed to generate password." → String(localized: "passwordGen.error.failed")
Button("Copy", ...) → Button(String(localized: "common.copy"), ...)
Button("Use") → Button(String(localized: "passwordGen.use"))
```

- [ ] **Step 5: Migrate GroupSidebarView (display-only recycle bin label)**

In `MyPass/UI/Sidebar/GroupSidebarView.swift`, add a private helper and replace display text only:

```swift
private var recycleBinDisplayName: String {
    String(localized: "sidebar.recycleBin")
}
```

Replace both `Text(GroupTreeOperations.recycleBinGroupName)` with `Text(recycleBinDisplayName)`.

**Do not** change `GroupTreeOperations.recycleBinGroupName` (`"Recycle Bin"`) or `addSubgroup(named: "New Group", ...)` — vault-stored names stay English.

- [ ] **Step 6: Build and run tests**

Run: `./scripts/test.sh`
Expected: all existing tests PASS; manual check — sidebar recycle bin shows **Кошик** with uk locale.

- [ ] **Step 7: Commit**

```bash
git add MyPass/Localizable.xcstrings MyPass/UI/EntryDetail/ MyPass/UI/EntryList/ MyPass/UI/PasswordGenerator/ MyPass/UI/Sidebar/GroupSidebarView.swift
git commit -m "feat: localize entry views, password generator, and sidebar"
```

---

### Task 6: Migrate SettingsView remaining strings + VaultSession errors + Face ID usage description

**Files:**
- Modify: `MyPass/Localizable.xcstrings`
- Modify: `MyPass/UI/Settings/SettingsView.swift`
- Modify: `MyPass/State/VaultSession.swift`
- Create: `MyPass/InfoPlist.xcstrings`
- Modify: `project.yml`
- Modify: `MyPass/State/SyncBackendOption.swift` (remove `defaultValue` fallbacks once keys exist)

**Interfaces:**
- Consumes: Task 1 `SyncBackendOption.displayName` keys; Task 3 Language section English restart hint.
- Produces: complete macOS UI catalog except audit fixes in Task 8; localized `NSFaceIDUsageDescription`.

**Info.plist localization approach:** Use **`InfoPlist.xcstrings`** (String Catalog for Info.plist keys, supported in Xcode 15+ while deployment target remains macOS 14). Remove inline `NSFaceIDUsageDescription` from `project.yml` `info.properties` and localize via catalog instead. Do **not** add legacy `en.lproj/InfoPlist.strings` unless `InfoPlist.xcstrings` fails to compile in your Xcode version.

- [ ] **Step 1: Append Settings + VaultSession catalog keys**

Add to `MyPass/Localizable.xcstrings`:

```json
    "settings.autoLock" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Automatische Sperre" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Auto-Lock" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Автоблокування" } }
      }
    },
    "settings.backups" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Sicherungen" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Backups" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Резервні копії" } }
      }
    },
    "settings.chromeExtension" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Chrome-Erweiterung" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Chrome Extension" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Розширення Chrome" } }
      }
    },
    "settings.chooseCertificate" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Zertifikat wählen…" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Choose Certificate…" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Обрати сертифікат…" } }
      }
    },
    "settings.chooseFolder" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Ordner wählen…" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Choose Folder…" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Обрати теку…" } }
      }
    },
    "settings.choosePrivateKey" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Privaten Schlüssel wählen…" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Choose Private Key…" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Обрати приватний ключ…" } }
      }
    },
    "settings.connectionSuccessful" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Verbindung erfolgreich" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Connection successful" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "З'єднання успішне" } }
      }
    },
    "settings.couldNotAccessFolder" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Auf den ausgewählten Ordner konnte nicht zugegriffen werden." } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Could not access the selected folder." } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Не вдалося отримати доступ до обраної теки." } }
      }
    },
    "settings.enterExtensionID" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Geben Sie die Erweiterungs-ID ein." } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Enter the extension ID." } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Введіть ID розширення." } }
      }
    },
    "settings.extensionID" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Erweiterungs-ID (chrome://extensions)" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Extension ID (chrome://extensions)" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "ID розширення (chrome://extensions)" } }
      }
    },
    "settings.field.host" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Host" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Host" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Хост" } }
      }
    },
    "settings.field.keyPassphrase" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Schlüssel-Passphrase (falls vorhanden)" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Key Passphrase (if any)" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Парольна фраза ключа (за потреби)" } }
      }
    },
    "settings.field.remotePath" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Remote-Pfad" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Remote Path" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Віддалений шлях" } }
      }
    },
    "settings.field.username" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Benutzername" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Username" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Ім'я користувача" } }
      }
    },
    "settings.folderSelected" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Ordner ausgewählt." } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Folder selected." } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Теку обрано." } }
      }
    },
    "settings.icloudAvailable" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "iCloud-Container ist verfügbar." } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "iCloud container is available." } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Контейнер iCloud доступний." } }
      }
    },
    "settings.icloudUnavailable" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "iCloud Drive ist nicht verfügbar — melden Sie sich bei iCloud an und aktivieren Sie iCloud Drive in den Systemeinstellungen." } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "iCloud Drive is unavailable — sign in to iCloud and enable iCloud Drive in System Settings." } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "iCloud Drive недоступний — увійдіть в iCloud і увімкніть iCloud Drive у системних налаштуваннях." } }
      }
    },
    "settings.icloudVerifyFailed" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "iCloud-Container konnte nicht überprüft werden: %@" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Could not verify iCloud container: %@" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Не вдалося перевірити контейнер iCloud: %@" } }
      }
    },
    "settings.installNativeHost" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Native-Messaging-Host installieren/aktualisieren" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Install/Update Native Messaging Host" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Встановити/оновити Native Messaging Host" } }
      }
    },
    "settings.installationFailed" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Installation fehlgeschlagen: %@" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Installation failed: %@" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Не вдалося встановити: %@" } }
      }
    },
    "settings.keepLast" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Behalten: %lld" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Keep last: %lld" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Зберігати останні: %lld" } }
      }
    },
    "settings.language.restartHint" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Die Sprachänderung wird nach einem Neustart von MyPass wirksam." } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Changing language takes effect after restarting MyPass." } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Зміна мови застосовується після перезапуску MyPass." } }
      }
    },
    "settings.language.section" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Sprache" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Language" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Мова" } }
      }
    },
    "settings.language.title" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Sprache" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Language" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Мова" } }
      }
    },
    "settings.manifestInstalled" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Manifest installiert." } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Manifest installed." } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Маніфест встановлено." } }
      }
    },
    "settings.noCertificateSelected" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Kein Zertifikat ausgewählt (optional)" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "No certificate selected (optional)" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Сертифікат не обрано (необов'язково)" } }
      }
    },
    "settings.noFolderSelected" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Kein Ordner ausgewählt." } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "No folder selected." } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Теку не обрано." } }
      }
    },
    "settings.noKeySelected" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Kein Schlüssel ausgewählt" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "No key selected" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Ключ не обрано" } }
      }
    },
    "settings.chooseNativeMessagingFolder" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Wählen Sie zuerst den NativeMessagingHosts-Ordner." } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Choose the NativeMessagingHosts folder first." } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Спочатку оберіть теку NativeMessagingHosts." } }
      }
    },
    "settings.port" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Port: %lld" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Port: %lld" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Порт: %lld" } }
      }
    },
    "settings.sync" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Synchronisierung" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Sync" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Синхронізація" } }
      }
    },
    "settings.syncBackend" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Backend" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Backend" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Бекенд" } }
      }
    },
    "settings.syncBackend.icloud" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "iCloud Drive" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "iCloud Drive" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "iCloud Drive" } }
      }
    },
    "settings.syncBackend.local" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Lokale Datei" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Local File" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Локальний файл" } }
      }
    },
    "settings.syncBackend.sftp" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "SFTP" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "SFTP" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "SFTP" } }
      }
    },
    "settings.syncNow" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Jetzt synchronisieren" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Sync Now" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Синхронізувати зараз" } }
      }
    },
    "settings.syncStarted" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Gestartet…" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Started…" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Запущено…" } }
      }
    },
    "settings.testConnection" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Verbindung testen" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Test Connection" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Перевірити з'єднання" } }
      }
    },
    "settings.timeout" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Zeitlimit: %lld Min." } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Timeout: %lld min" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Таймаут: %lld хв" } }
      }
    },
    "vaultSession.error.localSaveSyncFailed" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Lokal gespeichert, aber Synchronisierung fehlgeschlagen: %@" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Local save completed, but sync failed: %@" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Локальне збереження виконано, але синхронізація не вдалася: %@" } }
      }
    },
    "vaultSession.error.saveFailed" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Änderungen konnten nicht gespeichert werden: %@" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Failed to save changes: %@" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Не вдалося зберегти зміни: %@" } }
      }
    },
    "vaultSession.error.saveMergedFailed" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Zusammengeführte Änderungen konnten lokal nicht gespeichert werden: %@" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Failed to save merged changes locally: %@" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Не вдалося локально зберегти об'єднані зміни: %@" } }
      }
    },
    "vaultSession.error.syncFailed" : {
      "localizations" : {
        "de" : { "stringUnit" : { "state" : "translated", "value" : "Tresor konnte nicht synchronisiert werden: %@" } },
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Failed to sync vault: %@" } },
        "uk" : { "stringUnit" : { "state" : "translated", "value" : "Не вдалося синхронізувати сховище: %@" } }
      }
    }
```

Update `SyncBackendOption.displayName` to drop `defaultValue`:

```swift
case .local: return String(localized: "settings.syncBackend.local")
case .iCloud: return String(localized: "settings.syncBackend.icloud")
case .sftp: return String(localized: "settings.syncBackend.sftp")
```

- [ ] **Step 2: Migrate SettingsView literals**

Replace every user-visible string in `SettingsView.swift` with catalog keys. Representative patterns:

```swift
Section("Language") → Section(String(localized: "settings.language.section"))
Picker("Language", ...) → Picker(String(localized: "settings.language.title"), ...)
Text("Changing language takes effect after restarting MyPass.") → Text(String(localized: "settings.language.restartHint"))

Section("Auto-Lock") → Section(String(localized: "settings.autoLock"))
Stepper("Timeout: \(Int(autoLockTimeoutMinutes)) min", ...) → Stepper(String(format: String(localized: "settings.timeout"), Int64(autoLockTimeoutMinutes)), ...)

Section("Backups") → Section(String(localized: "settings.backups"))
Stepper("Keep last: \(backupCount)", ...) → Stepper(String(format: String(localized: "settings.keepLast"), Int64(backupCount)), ...)

Section("Sync") → Section(String(localized: "settings.sync"))
Picker("Backend", ...) → Picker(String(localized: "settings.syncBackend"), ...)
Button("Sync Now") → Button(String(localized: "settings.syncNow"))
manualSyncStatusMessage = "Started…" → String(localized: "settings.syncStarted")

Section("Chrome Extension") → Section(String(localized: "settings.chromeExtension"))
TextField("Extension ID (chrome://extensions)", ...) → TextField(String(localized: "settings.extensionID"), ...)
Text("Folder selected.") → Text(String(localized: "settings.folderSelected"))
Text("No folder selected.") → Text(String(localized: "settings.noFolderSelected"))
Button("Choose Folder…") → Button(String(localized: "settings.chooseFolder"))
Button("Install/Update Native Messaging Host") → Button(String(localized: "settings.installNativeHost"))

Text("iCloud container is available.") → Text(String(localized: "settings.icloudAvailable"))
"iCloud Drive is unavailable — ..." → String(localized: "settings.icloudUnavailable")
"Could not verify iCloud container: \(error)" → String(format: String(localized: "settings.icloudVerifyFailed"), String(describing: error))

TextField("Host", ...) → TextField(String(localized: "settings.field.host"), ...)
Stepper("Port: \(sftpPort)", ...) → Stepper(String(format: String(localized: "settings.port"), Int64(sftpPort)), ...)
TextField("Username", ...) → TextField(String(localized: "settings.field.username"), ...)
TextField("Remote Path", ...) → TextField(String(localized: "settings.field.remotePath"), ...)
SecureField("Key Passphrase (if any)", ...) → SecureField(String(localized: "settings.field.keyPassphrase"), ...)
sftpPrivateKeyPath.isEmpty ? "No key selected" : ... → sftpPrivateKeyPath.isEmpty ? String(localized: "settings.noKeySelected") : ...
sftpCertificatePath.isEmpty ? "No certificate selected (optional)" : ... → String(localized: "settings.noCertificateSelected")
Button("Choose Private Key…") → Button(String(localized: "settings.choosePrivateKey"))
Button("Choose Certificate…") → Button(String(localized: "settings.chooseCertificate"))
Button("Test Connection") → Button(String(localized: "settings.testConnection"))
Label("Connection successful", ...) → Label(String(localized: "settings.connectionSuccessful"), ...)

chromeInstallStatusMessage = "Enter the extension ID." → String(localized: "settings.enterExtensionID")
chromeInstallStatusMessage = "Choose the NativeMessagingHosts folder first." → String(localized: "settings.chooseNativeMessagingFolder")
chromeInstallStatusMessage = "Could not access the selected folder." → String(localized: "settings.couldNotAccessFolder")
chromeInstallStatusMessage = "Manifest installed." → String(localized: "settings.manifestInstalled")
chromeInstallStatusMessage = "Installation failed: \(error)" → String(format: String(localized: "settings.installationFailed"), String(describing: error))
```

- [ ] **Step 3: Migrate VaultSession error strings**

In `MyPass/State/VaultSession.swift`:

```swift
lastSaveError = "Failed to sync vault: \(error)"
→ lastSaveError = String(format: String(localized: "vaultSession.error.syncFailed"), String(describing: error))

lastSaveError = "Failed to save merged changes locally: \(error)"
→ lastSaveError = String(format: String(localized: "vaultSession.error.saveMergedFailed"), String(describing: error))

lastSaveError = "Failed to save changes: \(error)"
→ lastSaveError = String(format: String(localized: "vaultSession.error.saveFailed"), String(describing: error))

lastSaveError = "Local save completed, but sync failed: \(error)"
→ lastSaveError = String(format: String(localized: "vaultSession.error.localSaveSyncFailed"), String(describing: error))
```

- [ ] **Step 4: Localize Face ID usage description via InfoPlist.xcstrings**

Create `MyPass/InfoPlist.xcstrings`:

```json
{
  "sourceLanguage" : "en",
  "strings" : {
    "NSFaceIDUsageDescription" : {
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "MyPass verwendet Touch ID, um Ihren Passwort-Tresor schnell zu entsperren."
          }
        },
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "MyPass uses Touch ID to quickly unlock your password vault."
          }
        },
        "uk" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "MyPass використовує Touch ID для швидкого розблокування вашого сховища паролів."
          }
        }
      }
    }
  },
  "version" : "1.0"
}
```

Modify `project.yml` — remove inline Face ID string from `info.properties`:

```yaml
    info:
      path: MyPass/Info.plist
      properties:
        LSApplicationCategoryType: public.app-category.utilities
```

Ensure both catalogs are under `MyPass/` sources path (picked up automatically by XcodeGen).

- [ ] **Step 5: Run tests**

Run: `./scripts/test.sh`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add MyPass/Localizable.xcstrings MyPass/InfoPlist.xcstrings MyPass/UI/Settings/SettingsView.swift MyPass/State/VaultSession.swift MyPass/State/SyncBackendOption.swift project.yml
git commit -m "feat: localize Settings, vault errors, and Face ID usage description"
```

---

### Task 7: Chrome `_locales` en/uk/de + wire popup.js, content.js, manifest

**Files:**
- Create: `ChromeExtension/_locales/en/messages.json`
- Create: `ChromeExtension/_locales/uk/messages.json`
- Create: `ChromeExtension/_locales/de/messages.json`
- Modify: `ChromeExtension/manifest.json`
- Modify: `ChromeExtension/popup.js`
- Modify: `ChromeExtension/content.js`
- Create: `ChromeExtension/tests/i18n.messages.test.js`
- Modify: `scripts/test.sh` (add i18n test invocation)

**Interfaces:**
- Consumes: nothing from macOS tasks (Chrome follows browser locale independently in v1).
- Produces: `chrome.i18n.getMessage("key")` helper usage; manifest `default_locale: "en"`.

- [ ] **Step 1: Create English messages**

Create `ChromeExtension/_locales/en/messages.json`:

```json
{
  "extName": {
    "message": "MyPass"
  },
  "extDescription": {
    "message": "Autofill and save logins from MyPass"
  },
  "popupNotFound": {
    "message": "MyPass not found. Make sure the app is installed and has been launched at least once (to register the native messaging host)."
  },
  "popupUnlockVault": {
    "message": "Open MyPass and unlock the vault"
  },
  "popupNoLogins": {
    "message": "No saved logins for this site"
  },
  "popupSelectEntry": {
    "message": "Select an entry to autofill:"
  },
  "bannerSavePrompt": {
    "message": "Save password to MyPass?"
  },
  "bannerSave": {
    "message": "Save"
  }
}
```

- [ ] **Step 2: Create Ukrainian messages**

Create `ChromeExtension/_locales/uk/messages.json`:

```json
{
  "extName": {
    "message": "MyPass"
  },
  "extDescription": {
    "message": "Автозаповнення та збереження логінів із MyPass"
  },
  "popupNotFound": {
    "message": "MyPass не знайдено. Переконайтеся, що застосунок встановлено і хоча б раз запускали (щоб зареєструвати native messaging host)."
  },
  "popupUnlockVault": {
    "message": "Відкрийте MyPass і розблокуйте сховище"
  },
  "popupNoLogins": {
    "message": "Немає збережених логінів для цього сайту"
  },
  "popupSelectEntry": {
    "message": "Оберіть запис для автозаповнення:"
  },
  "bannerSavePrompt": {
    "message": "Зберегти пароль у MyPass?"
  },
  "bannerSave": {
    "message": "Зберегти"
  }
}
```

- [ ] **Step 3: Create German messages**

Create `ChromeExtension/_locales/de/messages.json`:

```json
{
  "extName": {
    "message": "MyPass"
  },
  "extDescription": {
    "message": "Anmeldungen aus MyPass automatisch ausfüllen und speichern"
  },
  "popupNotFound": {
    "message": "MyPass nicht gefunden. Stellen Sie sicher, dass die App installiert ist und mindestens einmal gestartet wurde (zur Registrierung des Native-Messaging-Hosts)."
  },
  "popupUnlockVault": {
    "message": "Öffnen Sie MyPass und entsperren Sie den Tresor"
  },
  "popupNoLogins": {
    "message": "Keine gespeicherten Anmeldungen für diese Website"
  },
  "popupSelectEntry": {
    "message": "Eintrag zum Ausfüllen auswählen:"
  },
  "bannerSavePrompt": {
    "message": "Passwort in MyPass speichern?"
  },
  "bannerSave": {
    "message": "Speichern"
  }
}
```

- [ ] **Step 4: Update manifest.json**

Replace `ChromeExtension/manifest.json` with:

```json
{
  "manifest_version": 3,
  "name": "__MSG_extName__",
  "version": "0.1.0",
  "description": "__MSG_extDescription__",
  "default_locale": "en",
  "permissions": ["nativeMessaging", "activeTab"],
  "background": {
    "service_worker": "background.js"
  },
  "action": {
    "default_popup": "popup.html"
  },
  "content_scripts": [
    {
      "matches": ["<all_urls>"],
      "js": ["content.js"],
      "run_at": "document_idle"
    }
  ]
}
```

- [ ] **Step 5: Wire popup.js**

At top of `ChromeExtension/popup.js`:

```javascript
function t(key) {
  return chrome.i18n.getMessage(key);
}
```

Replace string literals:

```javascript
setStatus('MyPass not found. Make sure the app is installed and has been launched at least once (to register the native messaging host).');
→ setStatus(t('popupNotFound'));

setStatus('Open MyPass and unlock the vault');
→ setStatus(t('popupUnlockVault'));

setStatus('No saved logins for this site');
→ setStatus(t('popupNoLogins'));

setStatus('Select an entry to autofill:');
→ setStatus(t('popupSelectEntry'));
```

- [ ] **Step 6: Wire content.js banner**

At top of the IIFE in `ChromeExtension/content.js`:

```javascript
function t(key) {
  return chrome.i18n.getMessage(key);
}
```

Replace:

```javascript
banner.textContent = 'Save password to MyPass?';
→ banner.textContent = t('bannerSavePrompt');

saveButton.textContent = 'Save';
→ saveButton.textContent = t('bannerSave');
```

- [ ] **Step 7: Add i18n unit test + extend test.sh**

Create `ChromeExtension/tests/i18n.messages.test.js`:

```javascript
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const localesDir = path.join(__dirname, '..', '_locales');
const requiredKeys = [
  'extName',
  'extDescription',
  'popupNotFound',
  'popupUnlockVault',
  'popupNoLogins',
  'popupSelectEntry',
  'bannerSavePrompt',
  'bannerSave',
];

for (const locale of ['en', 'uk', 'de']) {
  const filePath = path.join(localesDir, locale, 'messages.json');
  const messages = JSON.parse(fs.readFileSync(filePath, 'utf8'));
  for (const key of requiredKeys) {
    assert.ok(messages[key], `${locale}: missing key ${key}`);
    assert.ok(messages[key].message, `${locale}: empty message for ${key}`);
  }
}

const manifest = JSON.parse(
  fs.readFileSync(path.join(__dirname, '..', 'manifest.json'), 'utf8')
);
assert.strictEqual(manifest.default_locale, 'en');
assert.strictEqual(manifest.name, '__MSG_extName__');
assert.strictEqual(manifest.description, '__MSG_extDescription__');

console.log('Chrome i18n messages OK');
```

Add to `scripts/test.sh` after existing node tests:

```bash
  node ChromeExtension/tests/i18n.messages.test.js
```

Update `ChromeExtension/tests/background.manifest.test.js` — replace hard-coded name assertion:

```javascript
assert.strictEqual(manifest.name, '__MSG_extName__');
```

- [ ] **Step 8: Run Chrome tests**

Run:
```bash
node ChromeExtension/tests/background.manifest.test.js
node ChromeExtension/tests/formDetection.test.js
node ChromeExtension/tests/i18n.messages.test.js
```
Expected: all print `OK`.

Manual: set Chrome UI language to **Deutsch**, reload extension → popup status strings appear in German when triggered.

- [ ] **Step 9: Commit**

```bash
git add ChromeExtension/_locales ChromeExtension/manifest.json ChromeExtension/popup.js ChromeExtension/content.js ChromeExtension/tests scripts/test.sh
git commit -m "feat: localize Chrome extension via _locales and chrome.i18n"
```

---

### Task 8: Coverage audit + RUN.md testing section + how to add a language

**Files:**
- Modify: `RUN.md` (Ukrainian section only)
- Modify: `docs/superpowers/plans/2026-07-26-mypass-phase7-localization.md` (this file — optional changelog note only if needed during execution)

**Interfaces:**
- Consumes: all prior tasks complete.
- Produces: documented manual acceptance checklist; grep-verified zero hard-coded UI strings in `MyPass/UI`.

- [ ] **Step 1: Grep audit for remaining hard-coded UI strings**

Run:
```bash
rg -n 'Text\("[A-Za-z(]' MyPass/UI MyPass/ContentView.swift MyPass/MyPassApp.swift
rg -n 'Button\("[A-Za-z]' MyPass/UI MyPass/ContentView.swift
rg -n 'Section\("[A-Za-z]' MyPass/UI
rg -n 'Label\("[A-Za-z]' MyPass/UI
rg -n 'TextField\("[A-Za-z]' MyPass/UI
rg -n 'SecureField\("[A-Za-z]' MyPass/UI
rg -n 'Menu\("[A-Za-z]' MyPass/UI
rg -n 'Stepper\("[A-Za-z]' MyPass/UI
rg -n 'Toggle\("[A-Za-z]' MyPass/UI
rg -n 'Picker\("[A-Za-z]' MyPass/UI
rg -n 'lastSaveError = "' MyPass/State/VaultSession.swift
rg -n "'[A-Za-z].*'" ChromeExtension/popup.js ChromeExtension/content.js
```

Expected: **no matches** except:
- `GroupTreeOperations.recycleBinGroupName` / `"Recycle Bin"` in non-UI state code
- `"New Group"` in vault mutation code (`GroupSidebarView` context menu action)
- KeePass field keys (`"Title"`, `"UserName"`, etc.) in `EntryEditView` standardKeys sets
- `console.warn` debug strings in `content.js` (not user-visible UI)
- Language picker native labels in `AppLanguage.pickerLabel` (intentional)

Fix any unexpected matches before sign-off.

- [ ] **Step 2: Manual macOS acceptance checklist**

Run: `./scripts/run.sh`

| # | Check | Expected |
|---|-------|----------|
| 1 | Settings → Language → **Українська**, restart app | Unlock, Settings section titles, sidebar **Кошик** in Ukrainian |
| 2 | Settings → Language → **Deutsch**, restart app | Same surfaces in German |
| 3 | Settings → Language → **System** with macOS set to Ukrainian | UI follows system locale |
| 4 | Sync backend picker | Shows localized labels; UserDefaults stores `local`/`icloud`/`sftp` codes |
| 5 | Recycle bin entry | Stored group name in vault remains `"Recycle Bin"`; sidebar shows localized label |
| 6 | Vault entry title `"GitHub"` | Stays `"GitHub"` in all locales (not translated) |
| 7 | Save error alert | Localized title + localized error body from `VaultSession` |
| 8 | Touch ID prompt (if hardware available) | Localized usage string from `InfoPlist.xcstrings` |

- [ ] **Step 3: Manual Chrome acceptance checklist**

| # | Check | Expected |
|---|-------|----------|
| 1 | Chrome UI language **English** | Popup + save banner in English |
| 2 | Chrome UI language **Ukrainian** | Popup + save banner in Ukrainian |
| 3 | Chrome UI language **German** | Popup + save banner in German |
| 4 | MyPass app language **Deutsch**, Chrome **English** | Chrome stays English (v1: no app→extension locale sync) |
| 5 | `chrome://extensions` | Extension name/description localized via `__MSG_*__` |

- [ ] **Step 4: Add Ukrainian RUN.md section**

Append to `RUN.md` (keep entire file in Ukrainian):

```markdown
## Перевірка локалізації (Фаза 7)

### macOS

1. Запустіть `./scripts/run.sh`.
2. Відкрийте **MyPass → Settings → Language**.
3. Оберіть **Українська**, повністю закрийте застосунок і запустіть знову.
4. Перевірте екран розблокування, меню-бар, бічну панель (**Кошик**), налаштування та деталі запису.
5. Повторіть для **Deutsch** і **System** (змініть мову macOS у System Settings).

### Chrome

1. Змініть мову інтерфейсу Chrome: **Settings → Languages** (не мову MyPass).
2. Перезавантажте розширення на `chrome://extensions`.
3. Відкрийте popup і фікстурну сторінку — текст має відповідати мові Chrome.

### Як додати нову мову (лише каталоги)

1. **macOS:** додайте локаль у `MyPass/Localizable.xcstrings` і `MyPass/InfoPlist.xcstrings` (скопіюйте блок `"en"`, перекладіть `"value"`).
2. **macOS Settings picker (опційно):** додайте кейс у `AppLanguage` + рядок у picker — потрібно лише якщо мова має з’явитися в override; для locale-only через System цього може не знадобитися.
3. **Chrome:** створіть `ChromeExtension/_locales/<code>/messages.json` з тими ж ключами, що в `en/messages.json`.
4. Запустіть `./scripts/test.sh` і `node ChromeExtension/tests/i18n.messages.test.js` (оновіть список локалей у тесті).
5. Код Swift/JS **не змінюйте**, якщо ключі вже існують.
```

- [ ] **Step 5: Final test run**

Run: `./scripts/test.sh`
Expected: full suite PASS including `AppLanguageTests`, `SyncBackendOptionTests`, Chrome i18n test.

- [ ] **Step 6: Commit**

```bash
git add RUN.md
git commit -m "docs: add Ukrainian localization testing guide to RUN.md"
```

---

## Self-Review

| Spec acceptance criterion | Task(s) |
|---|---|
| All user-visible macOS strings via String Catalog | Tasks 4–6; verified Task 8 grep |
| en, uk, de catalogs complete for macOS UI | Tasks 4–6 (`Localizable.xcstrings` + `InfoPlist.xcstrings`) |
| Chrome popup, content script, banner localized | Task 7 |
| Settings language override changes macOS UI | Tasks 2–3 + catalog Tasks 4–6 |
| Adding a language = catalog entries only (documented) | Task 8 RUN.md procedure |
| English source locale in catalogs | Global Constraints; all JSON blocks |
| Vault content not translated | Global Constraints; Task 5 recycle bin split; audit Task 8 |
| Recycle Bin stored name `"Recycle Bin"` | Task 5 — `GroupTreeOperations.recycleBinGroupName` unchanged |
| Chrome follows browser locale, not app Settings | Task 7; Task 8 checklist row 4 |
| RUN.md stays Ukrainian | Task 8 — Ukrainian section only |
| SyncBackendOption stable codes before localization | Task 1 |
| No automated translation CI | Global Constraints |
| macOS 14+, Swift 5.10, XcodeGen | Global Constraints; `./scripts/generate.sh` in test steps |

**Placeholder scan:** No TBD/TODO/Similar-to-Task placeholders in this plan.

**Type consistency:** `AppLanguage.userDefaultsKey`, `SyncBackendOptionMigration.resolveStoredRawValue`, `LanguagePreferences.applyEarly`, and semantic catalog keys are consistent across Tasks 1–8.

**Plan complete and saved to `docs/superpowers/plans/2026-07-26-mypass-phase7-localization.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints

**Which approach?**
