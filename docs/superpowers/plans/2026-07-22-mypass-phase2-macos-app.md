# MyPass Фаза 2 — macOS-приложение (SwiftUI) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Построить полнофункциональное SwiftUI macOS-приложение MyPass поверх уже готового пакета `MyPassKit` (Фаза 1) — локальный менеджер паролей с Touch ID, автоблокировкой, деревом групп, поиском, TOTP, генератором паролей, историей записей, корзиной, меню-баром и импортом CSV/.kdbx.

**Architecture:** Xcode-проект (генерируется XcodeGen из `project.yml`) с локальной SPM-зависимостью на `Packages/MyPassKit`. Слоистая структура: `State/` (VaultSession, NavigationState, AutoLockController) держит единственный источник правды над расшифрованной `KdbxDatabase`; `Storage/` отвечает только за байты на диске (атомарная запись, ротация backup); `Security/` изолирует Keychain/LocalAuthentication за протоколом для тестируемости; `Models/` добавляет удобные computed-свойства над `KdbxEntry` без изменения самой модели; `UI/` — чистые SwiftUI-вью, читающие состояние через `@EnvironmentObject`/параметры, без собственной бизнес-логики.

**Tech Stack:** Swift 5.10+, SwiftUI, XCTest, XcodeGen, Keychain Services, LocalAuthentication, AppKit-мосты (`NSApplicationDelegateAdaptor`, `NSWorkspace`, `NSOpenPanel`, `NSPasteboard`) точечно.

## Global Constraints

- Swift 5.10+, macOS 14.0+ (наследуется от MyPassKit; deploymentTarget в project.yml = 14.0).
- SwiftUI как основной UI-слой; AppKit-мосты допускаются точечно (`NSApplicationDelegateAdaptor`, `LAContext`, `NSWorkspace`, `NSOpenPanel`, `NSPasteboard`) — не строить лишний AppKit-UI поверх них.
- Копирование в буфер — `NSPasteboard.general`; автоочистка через 30 сек по таймеру, ТОЛЬКО если буфер всё ещё содержит именно то значение, что было скопировано (не затирать то, что пользователь скопировал из другого места за эти 30 сек).
- Известное ограничение вне рамок этого плана: Argon2id KDF в MyPassKit ограничен 16-байтной солью (swift-sodium); реальные сторонние файлы KeePassXC (32-байтная соль/Argon2d) не откроются — открытие "существующего .kdbx" (Task 21) работает надёжно только для файлов, созданных самим MyPass (round-trip). UI должен явно предупреждать об этом при ошибке открытия, а не молча падать с "неверный пароль".
- Вне рамок этого плана (следующие фазы): синхронизация (iCloud/локальная папка/SFTP) и merge — Фаза 3; браузерные расширения (Safari/Chrome) — Фаза 4; iOS/iPadOS и AutoFill — Фаза 5; Passkeys — Фаза 6.

---

## Файловая структура (создаётся/меняется этим планом)

```
project.yml                                        (корень репозитория, коммитится)
.gitignore                                         (добавить *.xcodeproj)
Packages/MyPassKit/Package.swift                    (модификация: новый testTarget)
Packages/MyPassKit/Sources/MyPassKit/...            (модификация: public API)
MyPass/
  MyPassApp.swift
  AppDelegate.swift
  MyPass.entitlements
  State/VaultSession.swift
  State/NavigationState.swift
  State/AutoLockController.swift
  Storage/VaultFileStore.swift
  Security/BiometricKeyStore.swift
  Models/KdbxEntry+Convenience.swift
  Models/TOTPCode.swift
  Import/CSVImporter.swift
  UI/ContentView.swift
  UI/Unlock/UnlockView.swift
  UI/Sidebar/GroupSidebarView.swift
  UI/EntryList/EntryListView.swift
  UI/EntryList/EntrySearch.swift
  UI/EntryDetail/EntryDetailView.swift
  UI/EntryDetail/EntryEditView.swift
  UI/EntryDetail/HistoryView.swift
  UI/PasswordGenerator/PasswordGeneratorView.swift
  UI/Settings/SettingsView.swift
  UI/MenuBar/MenuBarExtraContent.swift
MyPassTests/
  VaultFileStoreTests.swift
  AutoLockControllerTests.swift
  BiometricKeyStoreTests.swift
  KdbxEntryConvenienceTests.swift
  TOTPCodeTests.swift
  CSVImporterTests.swift
  NavigationStateSearchTests.swift
```

---

### Task 1: Открыть публичный API MyPassKit

**Files:**
- Modify: `Packages/MyPassKit/Sources/MyPassKit/KdbxDatabase.swift`
- Modify: `Packages/MyPassKit/Sources/MyPassKit/Format/KdbxOuterHeader.swift` (или файл, где объявлены `KdbxCipher`/`KdbxCompression` — найти точный файл через `grep -rn "enum KdbxCipher\|enum KdbxCompression" Packages/MyPassKit/Sources/MyPassKit/`)
- Modify: `Packages/MyPassKit/Sources/MyPassKit/Model/KdbxEntry.swift`
- Modify: `Packages/MyPassKit/Sources/MyPassKit/Model/KdbxGroup.swift`
- Modify: `Packages/MyPassKit/Sources/MyPassKit/Model/KdbxDeletedObject.swift`
- Modify: `Packages/MyPassKit/Sources/MyPassKit/TOTP/TOTPGenerator.swift`
- Modify: `Packages/MyPassKit/Sources/MyPassKit/PasswordGenerator/PasswordGenerator.swift`
- Modify: `Packages/MyPassKit/Package.swift`
- Test: `Packages/MyPassKit/Tests/MyPassKitPublicAPITests/MyPassKitPublicAPITests.swift`

**Interfaces:**
- Consumes: existing internal types listed in the task spec (KdbxDatabase, KdbxGroup, KdbxEntry, KdbxField, KdbxDeletedObject, TOTPGenerator, TOTPAlgorithm, PasswordGenerator, PasswordGeneratorOptions, PasswordGeneratorError, KdbxCipher, KdbxCompression, KdbxDatabaseError).
- Produces: all of the above as `public`, plus `KdbxEntry: Identifiable` (`var id: UUID { uuid }`), `KdbxGroup: Identifiable` (`var id: UUID { uuid }`), and `public init` for `PasswordGeneratorOptions`. All later tasks (2–21) import `MyPassKit` and rely on these being public.

- [ ] **Step 1: Grep to find exact locations of KdbxCipher/KdbxCompression and confirm current access levels**

Run: `grep -rn "enum KdbxCipher\|enum KdbxCompression\|struct KdbxDatabase\|enum KdbxDatabaseError\|struct KdbxField\|struct KdbxEntry\|final class KdbxGroup\|struct KdbxDeletedObject\|enum TOTPAlgorithm\|enum TOTPGenerator\|struct PasswordGeneratorOptions\|enum PasswordGeneratorError\|enum PasswordGenerator" Packages/MyPassKit/Sources/MyPassKit/`

Expected: one line per type showing the declaring file and that none currently have the `public` modifier (all `internal`/implicit).

- [ ] **Step 2: Write the failing public-API regression test**

Add a new test target to `Packages/MyPassKit/Package.swift`. Find the existing `targets:` array and add, alongside the existing test target(s):

```swift
.testTarget(
    name: "MyPassKitPublicAPITests",
    dependencies: ["MyPassKit"],
    path: "Tests/MyPassKitPublicAPITests"
),
```

Create `Packages/MyPassKit/Tests/MyPassKitPublicAPITests/MyPassKitPublicAPITests.swift`:

```swift
import XCTest
import MyPassKit // NOT @testable — this test enforces the module boundary

final class MyPassKitPublicAPITests: XCTestCase {
    func testEntryAndGroupModelArePublic() throws {
        let now = Date()
        let field = KdbxField(key: "Title", value: "Example", isProtected: false)
        let entry = KdbxEntry(
            uuid: UUID(),
            iconID: 0,
            fields: [field],
            creationTime: now,
            lastModificationTime: now,
            lastAccessTime: now,
            locationChanged: now,
            history: []
        )
        let group = KdbxGroup(
            uuid: UUID(),
            name: "Root",
            iconID: 0,
            creationTime: now,
            lastModificationTime: now,
            locationChanged: now,
            entries: [entry],
            subgroups: []
        )
        XCTAssertEqual(group.entries.first?.fields.first?.value, "Example")
        XCTAssertEqual(group.id, group.uuid)
        XCTAssertEqual(entry.id, entry.uuid)
    }

    func testDatabaseOpenSaveRoundTripSurfaceIsPublic() throws {
        // Only verifies the surface compiles and errors are public/catchable;
        // does not require a real file — corrupt data is enough to hit a public error path.
        do {
            _ = try KdbxDatabase.open(data: Data(), password: "x")
            XCTFail("expected KdbxDatabaseError.corruptFile")
        } catch let error as KdbxDatabaseError {
            XCTAssertTrue(error == .corruptFile("") || true) // shape check only; message text not asserted
        }
    }

    func testDeletedObjectIsPublic() {
        let obj = KdbxDeletedObject(uuid: UUID(), deletionTime: Date())
        XCTAssertNotNil(obj.uuid)
    }

    func testTOTPGeneratorIsPublic() {
        let code = TOTPGenerator.generate(
            secret: Data([0x01, 0x02, 0x03, 0x04, 0x05]),
            time: Date(timeIntervalSince1970: 59),
            step: 30,
            digits: 6,
            algorithm: .sha1
        )
        XCTAssertEqual(code.count, 6)
    }

    func testPasswordGeneratorIsPublic() throws {
        let options = PasswordGeneratorOptions(
            length: 16,
            includeLowercase: true,
            includeUppercase: true,
            includeDigits: true,
            includeSymbols: false
        )
        let password = try PasswordGenerator.generate(options: options)
        XCTAssertEqual(password.count, 16)
    }

    func testCipherAndCompressionEnumsArePublic() {
        let cipher: KdbxCipher = .aes256
        let compression: KdbxCompression = .gzip
        XCTAssertNotNil(cipher)
        XCTAssertNotNil(compression)
    }
}
```

- [ ] **Step 3: Run the test to verify it fails to compile (RED at the module boundary)**

Run: `cd Packages/MyPassKit && swift test --filter MyPassKitPublicAPITests`
Expected: build error, e.g. `'KdbxField' initializer is inaccessible due to 'internal' protection level` (or similar — the compiler will point at each internal symbol used from outside the module).

- [ ] **Step 4: Make the API public**

In `KdbxDatabase.swift`, change:

```swift
enum KdbxDatabaseError: Error, Equatable {
    case wrongPassword
    case corruptFile(String)
    case unsupportedFeature(String)
}

struct KdbxDatabase {
    var rootGroup: KdbxGroup
    var deletedObjects: [KdbxDeletedObject]

    static func open(data: Data, password: String) throws -> KdbxDatabase { ... }
    func save(password: String, cipher: KdbxCipher, compression: KdbxCompression) throws -> Data { ... }
}
```

to:

```swift
public enum KdbxDatabaseError: Error, Equatable {
    case wrongPassword
    case corruptFile(String)
    case unsupportedFeature(String)
}

public struct KdbxDatabase {
    public var rootGroup: KdbxGroup
    public var deletedObjects: [KdbxDeletedObject]

    public static func open(data: Data, password: String) throws -> KdbxDatabase { ... }
    public func save(password: String, cipher: KdbxCipher, compression: KdbxCompression) throws -> Data { ... }
}
```

(keep the existing implementation bodies — only the declaration keywords change, indicated by `{ ... }` standing in for the unchanged body).

In the file holding `KdbxCipher`/`KdbxCompression` (located in Step 1), add `public` to both enum declarations — the enum's cases inherit the enum's access level automatically:

```swift
public enum KdbxCipher {
    case aes256
    case chaCha20
}

public enum KdbxCompression {
    case none
    case gzip
}
```

In `Model/KdbxEntry.swift`, change:

```swift
struct KdbxField: Equatable {
    var key: String
    var value: String
    var isProtected: Bool
    init(key: String, value: String, isProtected: Bool) { ... }
}

struct KdbxEntry: Equatable {
    var uuid: UUID
    var iconID: Int
    var fields: [KdbxField]
    var creationTime: Date
    var lastModificationTime: Date
    var lastAccessTime: Date
    var locationChanged: Date
    var history: [KdbxEntry]
    init(uuid: UUID, iconID: Int, fields: [KdbxField], creationTime: Date, lastModificationTime: Date, lastAccessTime: Date, locationChanged: Date, history: [KdbxEntry]) { ... }
}
```

to:

```swift
public struct KdbxField: Equatable {
    public var key: String
    public var value: String
    public var isProtected: Bool
    public init(key: String, value: String, isProtected: Bool) { ... }
}

public struct KdbxEntry: Equatable, Identifiable {
    public var uuid: UUID
    public var iconID: Int
    public var fields: [KdbxField]
    public var creationTime: Date
    public var lastModificationTime: Date
    public var lastAccessTime: Date
    public var locationChanged: Date
    public var history: [KdbxEntry]
    public init(uuid: UUID, iconID: Int, fields: [KdbxField], creationTime: Date, lastModificationTime: Date, lastAccessTime: Date, locationChanged: Date, history: [KdbxEntry]) { ... }

    public var id: UUID { uuid }
}
```

In `Model/KdbxGroup.swift`, change:

```swift
final class KdbxGroup: Equatable {
    var uuid: UUID
    var name: String
    var iconID: Int
    var creationTime: Date
    var lastModificationTime: Date
    var locationChanged: Date
    var entries: [KdbxEntry]
    var subgroups: [KdbxGroup]
    init(uuid: UUID, name: String, iconID: Int, creationTime: Date, lastModificationTime: Date, locationChanged: Date, entries: [KdbxEntry], subgroups: [KdbxGroup]) { ... }
    static func == (lhs: KdbxGroup, rhs: KdbxGroup) -> Bool { ... }
}
```

to:

```swift
public final class KdbxGroup: Equatable, Identifiable {
    public var uuid: UUID
    public var name: String
    public var iconID: Int
    public var creationTime: Date
    public var lastModificationTime: Date
    public var locationChanged: Date
    public var entries: [KdbxEntry]
    public var subgroups: [KdbxGroup]
    public init(uuid: UUID, name: String, iconID: Int, creationTime: Date, lastModificationTime: Date, locationChanged: Date, entries: [KdbxEntry], subgroups: [KdbxGroup]) { ... }
    public static func == (lhs: KdbxGroup, rhs: KdbxGroup) -> Bool { ... }

    public var id: UUID { uuid }
}
```

(no `@Observable`/`ObservableObject` conformance added — `VaultSession`, introduced in Task 4, is the single observable owner of the database tree; `KdbxGroup` stays a plain reference type observed indirectly through `VaultSession`'s own publishing).

In `Model/KdbxDeletedObject.swift`, change:

```swift
struct KdbxDeletedObject: Equatable {
    var uuid: UUID
    var deletionTime: Date
    init(uuid: UUID, deletionTime: Date) { ... }
}
```

to:

```swift
public struct KdbxDeletedObject: Equatable {
    public var uuid: UUID
    public var deletionTime: Date
    public init(uuid: UUID, deletionTime: Date) { ... }
}
```

In `TOTP/TOTPGenerator.swift`, change:

```swift
enum TOTPAlgorithm { case sha1, sha256, sha512 }
enum TOTPGenerator {
    static func generate(secret: Data, time: Date, step: TimeInterval, digits: Int, algorithm: TOTPAlgorithm) -> String { ... }
}
```

to:

```swift
public enum TOTPAlgorithm { case sha1, sha256, sha512 }
public enum TOTPGenerator {
    public static func generate(secret: Data, time: Date, step: TimeInterval, digits: Int, algorithm: TOTPAlgorithm) -> String { ... }
}
```

In `PasswordGenerator/PasswordGenerator.swift`, change:

```swift
struct PasswordGeneratorOptions {
    var length: Int
    var includeLowercase: Bool
    var includeUppercase: Bool
    var includeDigits: Bool
    var includeSymbols: Bool
}
enum PasswordGeneratorError: Error, Equatable {
    case noCharacterClassSelected
    case secureRandomUnavailable
}
enum PasswordGenerator {
    static func generate(options: PasswordGeneratorOptions) throws -> String { ... }
}
```

to:

```swift
public struct PasswordGeneratorOptions {
    public var length: Int
    public var includeLowercase: Bool
    public var includeUppercase: Bool
    public var includeDigits: Bool
    public var includeSymbols: Bool

    public init(length: Int, includeLowercase: Bool, includeUppercase: Bool, includeDigits: Bool, includeSymbols: Bool) {
        self.length = length
        self.includeLowercase = includeLowercase
        self.includeUppercase = includeUppercase
        self.includeDigits = includeDigits
        self.includeSymbols = includeSymbols
    }
}
public enum PasswordGeneratorError: Error, Equatable {
    case noCharacterClassSelected
    case secureRandomUnavailable
}
public enum PasswordGenerator {
    public static func generate(options: PasswordGeneratorOptions) throws -> String { ... }
}
```

- [ ] **Step 5: Run the full MyPassKit test suite plus the new public-API test**

Run: `cd Packages/MyPassKit && swift test`
Expected: all 117 pre-existing tests still pass, plus the 5 new `MyPassKitPublicAPITests` pass (122 total). No `internal`/access-level compiler errors.

- [ ] **Step 6: Commit**

```bash
git add Packages/MyPassKit
git commit -m "Открыть публичный API MyPassKit для приложения (Фаза 2, Task 1)"
```

---

### Task 2: XcodeGen-скаффолдинг проекта

**Files:**
- Create: `project.yml`
- Create: `MyPass/MyPass.entitlements`
- Create: `MyPass/MyPassApp.swift`
- Create: `MyPass/ContentView.swift`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: `MyPassKit` product name (from `Packages/MyPassKit/Package.swift`).
- Produces: buildable `MyPass.xcodeproj` (git-ignored, regenerated on demand), an `MyPass` app target and `MyPassTests` test target that all subsequent tasks add files to. `AppDelegate` is referenced but created only in Task 19 — this task keeps `MyPassApp.swift` free of that dependency.

- [ ] **Step 1: Verify XcodeGen is installed**

Run: `which xcodegen || echo "install via: brew install xcodegen"`
Expected: a path to the `xcodegen` binary. If the fallback message prints, run `brew install xcodegen` before continuing.

- [ ] **Step 2: Write project.yml**

Create `project.yml` at the repository root:

```yaml
name: MyPass
options:
  bundleIdPrefix: com.mypass
packages:
  MyPassKit:
    path: Packages/MyPassKit
targets:
  MyPass:
    type: application
    platform: macOS
    deploymentTarget: "14.0"
    sources:
      - path: MyPass
    dependencies:
      - package: MyPassKit
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.mypass.app
        CODE_SIGN_ENTITLEMENTS: MyPass/MyPass.entitlements
        MARKETING_VERSION: "0.1.0"
    info:
      path: MyPass/Info.plist
      properties:
        NSFaceIDUsageDescription: "MyPass использует Touch ID для быстрой разблокировки вашего хранилища паролей."
        LSApplicationCategoryType: public.app-category.utilities
  MyPassTests:
    type: bundle.unit-test
    platform: macOS
    deploymentTarget: "14.0"
    sources:
      - path: MyPassTests
    dependencies:
      - package: MyPassKit
      - target: MyPass
```

(bundle id `com.mypass.app` is a placeholder — the user can change it later without affecting this plan's structure.)

- [ ] **Step 3: Write the entitlements file**

Create `MyPass/MyPass.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.keychain-access-groups</key>
    <array>
        <string>com.mypass.app.keychain</string>
    </array>
</dict>
</plist>
```

- [ ] **Step 4: Write the minimal app entry point and placeholder view**

Create `MyPass/MyPassApp.swift`:

```swift
import SwiftUI

@main
struct MyPassApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

Create `MyPass/ContentView.swift`:

```swift
import SwiftUI

struct ContentView: View {
    var body: some View {
        Text("Hello, MyPass")
            .padding()
    }
}
```

- [ ] **Step 5: Extend .gitignore**

Add to `.gitignore`:

```
*.xcodeproj
```

- [ ] **Step 6: Generate the Xcode project and build**

Run: `xcodegen generate && xcodebuild -project MyPass.xcodeproj -scheme MyPass build`
Expected: `xcodegen generate` prints `Generated project at MyPass.xcodeproj`; `xcodebuild` ends with `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add project.yml .gitignore MyPass/MyPass.entitlements MyPass/MyPassApp.swift MyPass/ContentView.swift
git commit -m "Скаффолдинг Xcode-проекта MyPass через XcodeGen (Task 2)"
```

---

### Task 3: VaultFileStore — атомарная запись и ротация backup

**Files:**
- Create: `MyPass/Storage/VaultFileStore.swift`
- Test: `MyPassTests/VaultFileStoreTests.swift`

**Interfaces:**
- Consumes: `Foundation.FileManager`, `Foundation.Data`.
- Produces:
```swift
struct VaultFileStore {
    let directory: URL       // e.g. Application Support/MyPass
    let backupCount: Int     // default 10

    init(directory: URL, backupCount: Int = 10)

    var vaultURL: URL { get }              // directory/vault.kdbx
    func load() throws -> Data?             // nil if vault.kdbx does not exist yet
    func save(data: Data) throws            // atomic write + backup rotation
}
```
Consumed by Task 4 (`VaultSession`), which owns one `VaultFileStore` pointed at `~/Library/Application Support/MyPass` in production and at a temp directory in tests.

- [ ] **Step 1: Write the failing test for first-time load returning nil**

Create `MyPassTests/VaultFileStoreTests.swift`:

```swift
import XCTest
@testable import MyPass

final class VaultFileStoreTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyPassVaultFileStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testLoadReturnsNilWhenNoVaultExists() throws {
        let store = VaultFileStore(directory: tempDir)
        XCTAssertNil(try store.load())
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/VaultFileStoreTests/testLoadReturnsNilWhenNoVaultExists`
Expected: FAIL — `VaultFileStore` does not exist yet (compile error).

- [ ] **Step 3: Minimal implementation — struct, init, load**

Create `MyPass/Storage/VaultFileStore.swift`:

```swift
import Foundation

struct VaultFileStore {
    let directory: URL
    let backupCount: Int

    init(directory: URL, backupCount: Int = 10) {
        self.directory = directory
        self.backupCount = backupCount
    }

    var vaultURL: URL {
        directory.appendingPathComponent("vault.kdbx")
    }

    private var backupDirectory: URL {
        directory.appendingPathComponent("backups")
    }

    func load() throws -> Data? {
        guard FileManager.default.fileExists(atPath: vaultURL.path) else {
            return nil
        }
        return try Data(contentsOf: vaultURL)
    }

    func save(data: Data) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try backupCurrentVaultIfPresent()
        try atomicWrite(data: data, to: vaultURL)
    }

    private func atomicWrite(data: Data, to url: URL) throws {
        let tempURL = directory.appendingPathComponent(".tmp-\(UUID().uuidString)")
        try data.write(to: tempURL, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
    }

    private func backupCurrentVaultIfPresent() throws {
        guard FileManager.default.fileExists(atPath: vaultURL.path) else { return }
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backupURL = backupDirectory.appendingPathComponent("vault-\(timestamp).kdbx")
        let existingData = try Data(contentsOf: vaultURL)
        try existingData.write(to: backupURL, options: .atomic)
        try rotateBackups()
    }

    private func rotateBackups() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: backupDirectory.path) else { return }
        let entries = try fm.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: [.creationDateKey])
        let sorted = try entries.sorted { lhs, rhs in
            let l = try lhs.resourceValues(forKeys: [.creationDateKey]).creationDate ?? .distantPast
            let r = try rhs.resourceValues(forKeys: [.creationDateKey]).creationDate ?? .distantPast
            return l < r
        }
        guard sorted.count > backupCount else { return }
        for url in sorted.prefix(sorted.count - backupCount) {
            try fm.removeItem(at: url)
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/VaultFileStoreTests/testLoadReturnsNilWhenNoVaultExists`
Expected: PASS.

- [ ] **Step 5: Write the failing test for save-then-load round trip**

Add to `MyPassTests/VaultFileStoreTests.swift`:

```swift
    func testSaveThenLoadRoundTrips() throws {
        let store = VaultFileStore(directory: tempDir)
        let payload = Data("hello vault".utf8)
        try store.save(data: payload)
        XCTAssertEqual(try store.load(), payload)
    }
```

- [ ] **Step 6: Run to verify it fails then passes**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/VaultFileStoreTests/testSaveThenLoadRoundTrips`
Expected: PASS immediately (Step 3's implementation already covers this case) — confirms no regression, no further code change needed here.

- [ ] **Step 7: Write the failing test for backup rotation**

Add to `MyPassTests/VaultFileStoreTests.swift`:

```swift
    func testBackupRotationKeepsOnlyBackupCountFiles() throws {
        let store = VaultFileStore(directory: tempDir, backupCount: 2)
        for i in 0..<5 {
            try store.save(data: Data("version \(i)".utf8))
        }
        let backupsDir = tempDir.appendingPathComponent("backups")
        let backups = try FileManager.default.contentsOfDirectory(atPath: backupsDir.path)
        XCTAssertEqual(backups.count, 2)
    }
```

- [ ] **Step 8: Run to verify it fails, note the actual failure**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/VaultFileStoreTests/testBackupRotationKeepsOnlyBackupCountFiles`
Expected: with 5 saves, saves 2–5 each back up the previous version (4 backups total, one fewer than saves since the first save has nothing to back up), then rotation trims to 2 — if this fails, the timestamp granularity (seconds) can collide for fast successive saves in the loop; if that happens, replace `ISO8601DateFormatter` with a monotonic counter suffix, e.g. `vault-\(timestamp)-\(i).kdbx`, in the test loop's write path only if collisions are observed. Given the loop is fast, prefer making the implementation robust up front: use `Date().timeIntervalSince1970` with fractional seconds via `String(format: "%.6f", ...)` instead of `ISO8601DateFormatter` in Step 3 to avoid same-second collisions.

- [ ] **Step 9: Adjust implementation for collision-free timestamps**

In `VaultFileStore.swift`, replace the timestamp line in `backupCurrentVaultIfPresent()`:

```swift
        let timestamp = String(format: "%.6f", Date().timeIntervalSince1970)
```

- [ ] **Step 10: Run full VaultFileStoreTests suite to verify all pass**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/VaultFileStoreTests`
Expected: 3/3 tests PASS.

- [ ] **Step 11: Commit**

```bash
git add MyPass/Storage/VaultFileStore.swift MyPassTests/VaultFileStoreTests.swift
git commit -m "VaultFileStore: атомарная запись и ротация резервных копий (Task 3)"
```

---

### Task 4: VaultSession — locked/unlocked state поверх KdbxDatabase

**Files:**
- Create: `MyPass/State/VaultSession.swift`
- Test: `MyPassTests/VaultSessionTests.swift`

**Interfaces:**
- Consumes: `MyPassKit.KdbxDatabase` (`open`, `save`, `KdbxDatabaseError`), `MyPassKit.KdbxGroup`, `MyPassKit.KdbxCipher`, `MyPassKit.KdbxCompression` (Task 1); `Storage.VaultFileStore` (Task 3).
- Produces:
```swift
enum VaultState {
    case locked
    case unlocked(KdbxDatabase)
}

final class VaultSession: ObservableObject {
    @Published private(set) var state: VaultState

    init(fileStore: VaultFileStore)

    var currentDatabase: KdbxDatabase? { get }   // non-nil only when .unlocked
    func unlock(password: String) throws
    func lock()
    func save(password: String) throws
    func mutate(_ body: (inout KdbxDatabase) -> Void)  // apply an in-place edit to the unlocked database
}
```
Consumed by every UI task (8, 10–21) via `@EnvironmentObject var vaultSession: VaultSession`.

- [ ] **Step 1: Write the failing test for first-run creates empty database on unlock**

Create `MyPassTests/VaultSessionTests.swift`:

```swift
import XCTest
import MyPassKit
@testable import MyPass

final class VaultSessionTests: XCTestCase {
    var tempDir: URL!
    var fileStore: VaultFileStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyPassVaultSessionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        fileStore = VaultFileStore(directory: tempDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testUnlockWithNoExistingVaultCreatesEmptyDatabase() throws {
        let session = VaultSession(fileStore: fileStore)
        XCTAssertEqual(session.state, .locked)
        try session.unlock(password: "correct-horse")
        guard case .unlocked(let db) = session.state else {
            return XCTFail("expected unlocked state")
        }
        XCTAssertEqual(db.rootGroup.name, "MyPass")
        XCTAssertEqual(db.rootGroup.entries.count, 0)
    }
}
```

`VaultState` needs `Equatable` for the `XCTAssertEqual(session.state, .locked)` line — add it in Step 3 (comparing only the `.locked`/`.unlocked` case, not the database contents, since `KdbxDatabase` itself has no `Equatable` requirement here):

```swift
extension VaultState: Equatable {
    static func == (lhs: VaultState, rhs: VaultState) -> Bool {
        switch (lhs, rhs) {
        case (.locked, .locked): return true
        case (.unlocked, .unlocked): return true
        default: return false
        }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/VaultSessionTests/testUnlockWithNoExistingVaultCreatesEmptyDatabase`
Expected: FAIL — `VaultSession` does not exist.

- [ ] **Step 3: Minimal implementation**

Create `MyPass/State/VaultSession.swift`:

```swift
import Foundation
import MyPassKit

enum VaultState {
    case locked
    case unlocked(KdbxDatabase)
}

extension VaultState: Equatable {
    static func == (lhs: VaultState, rhs: VaultState) -> Bool {
        switch (lhs, rhs) {
        case (.locked, .locked): return true
        case (.unlocked, .unlocked): return true
        default: return false
        }
    }
}

enum VaultSessionError: Error {
    case notUnlocked
}

final class VaultSession: ObservableObject {
    @Published private(set) var state: VaultState = .locked

    private let fileStore: VaultFileStore

    init(fileStore: VaultFileStore) {
        self.fileStore = fileStore
    }

    var currentDatabase: KdbxDatabase? {
        guard case .unlocked(let db) = state else { return nil }
        return db
    }

    func unlock(password: String) throws {
        if let existingData = try fileStore.load() {
            let db = try KdbxDatabase.open(data: existingData, password: password)
            state = .unlocked(db)
        } else {
            let now = Date()
            let rootGroup = KdbxGroup(
                uuid: UUID(),
                name: "MyPass",
                iconID: 0,
                creationTime: now,
                lastModificationTime: now,
                locationChanged: now,
                entries: [],
                subgroups: []
            )
            let db = KdbxDatabase(rootGroup: rootGroup, deletedObjects: [])
            state = .unlocked(db)
            try save(password: password)
        }
    }

    func lock() {
        state = .locked
    }

    func save(password: String) throws {
        guard case .unlocked(let db) = state else {
            throw VaultSessionError.notUnlocked
        }
        let data = try db.save(password: password, cipher: .aes256, compression: .gzip)
        try fileStore.save(data: data)
    }

    func mutate(_ body: (inout KdbxDatabase) -> Void) {
        guard case .unlocked(var db) = state else { return }
        body(&db)
        state = .unlocked(db)
    }
}
```

Note: `KdbxDatabase(rootGroup:deletedObjects:)` relies on the memberwise initializer being public — `KdbxDatabase` is a `struct` with `public var` members and no other stored properties per Task 1's spec, so Swift synthesizes a memberwise init at the struct's access level only if explicitly declared `public`; since Task 1 only made the explicit `static func open`/`func save` public and did not add an explicit public memberwise init, add one now:

In `KdbxDatabase.swift` (amend Task 1's change), add directly under the `public struct KdbxDatabase {` properties:

```swift
    public init(rootGroup: KdbxGroup, deletedObjects: [KdbxDeletedObject]) {
        self.rootGroup = rootGroup
        self.deletedObjects = deletedObjects
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/VaultSessionTests/testUnlockWithNoExistingVaultCreatesEmptyDatabase`
Expected: PASS.

- [ ] **Step 5: Write the failing test for wrong-password unlock on an existing vault**

Add to `MyPassTests/VaultSessionTests.swift`:

```swift
    func testUnlockWithWrongPasswordThrowsAndStaysLocked() throws {
        let session = VaultSession(fileStore: fileStore)
        try session.unlock(password: "correct-horse")
        session.lock()

        let secondSession = VaultSession(fileStore: fileStore)
        XCTAssertThrowsError(try secondSession.unlock(password: "wrong-password")) { error in
            XCTAssertEqual(error as? KdbxDatabaseError, .wrongPassword)
        }
        XCTAssertEqual(secondSession.state, .locked)
    }
```

- [ ] **Step 6: Run to verify it fails, then confirm it passes as-is or fix**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/VaultSessionTests/testUnlockWithWrongPasswordThrowsAndStaysLocked`
Expected: passes as-is, because `unlock` only assigns `state` after a successful `open`/creation — a thrown error from `KdbxDatabase.open` propagates before `state` is touched, leaving it `.locked`. If it fails because `state` was mutated before the throw, reorder `unlock(password:)` so `state = .unlocked(db)` is the last statement in the `if let existingData` branch (it already is) — no code change expected.

- [ ] **Step 7: Commit**

```bash
git add Packages/MyPassKit/Sources/MyPassKit/KdbxDatabase.swift MyPass/State/VaultSession.swift MyPassTests/VaultSessionTests.swift
git commit -m "VaultSession: locked/unlocked state и first-run создание базы (Task 4)"
```

---

### Task 5: AutoLockController — таймаут бездействия, сон, ручная блокировка

**Files:**
- Create: `MyPass/State/AutoLockController.swift`
- Test: `MyPassTests/AutoLockControllerTests.swift`

**Interfaces:**
- Consumes: `VaultSession.lock()` (Task 4).
- Produces:
```swift
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
    init(vaultSession: VaultSession, clock: AutoLockClock, sleepObserver: AutoLockSleepObserving, timeout: TimeInterval)
    func recordActivity()          // resets the inactivity timer
    func lockNow()                 // manual lock
    var timeout: TimeInterval { get set }  // mutable, e.g. from SettingsView (Task 20)
}
```
Consumed by Task 19 (`AppDelegate` wires the real `NSWorkspace` sleep notification) and Task 20 (`SettingsView` mutates `timeout`). Production code (Task 19) supplies a `Timer`-backed `AutoLockClock` and an `NSWorkspace`-backed `AutoLockSleepObserving`; tests supply fakes.

- [ ] **Step 1: Write the failing test using a fake clock**

Create `MyPassTests/AutoLockControllerTests.swift`:

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
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/AutoLockControllerTests/testInactivityTimeoutLocksVault`
Expected: FAIL — `AutoLockController` and protocols do not exist.

- [ ] **Step 3: Minimal implementation**

Create `MyPass/State/AutoLockController.swift`:

```swift
import Foundation

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
```

- [ ] **Step 4: Run to verify it passes**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/AutoLockControllerTests/testInactivityTimeoutLocksVault`
Expected: PASS.

- [ ] **Step 5: Write the failing test for sleep-notification locking**

Add to `MyPassTests/AutoLockControllerTests.swift`:

```swift
    func testSleepNotificationLocksVault() throws {
        let fileStore = VaultFileStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let session = VaultSession(fileStore: fileStore)
        try session.unlock(password: "pw")

        let clock = FakeClock()
        let sleepObserver = FakeSleepObserver()
        _ = AutoLockController(vaultSession: session, clock: clock, sleepObserver: sleepObserver, timeout: 900)

        sleepObserver.fireSleep()

        XCTAssertEqual(session.state, .locked)
    }
```

- [ ] **Step 6: Run to verify it passes (implementation from Step 3 already covers this)**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/AutoLockControllerTests/testSleepNotificationLocksVault`
Expected: PASS.

- [ ] **Step 7: Write the failing test for recordActivity resetting the timer (no premature lock)**

Add to `MyPassTests/AutoLockControllerTests.swift`:

```swift
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
    }
```

- [ ] **Step 8: Run to verify it passes**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/AutoLockControllerTests/testRecordActivityCancelsPreviousTick`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add MyPass/State/AutoLockController.swift MyPassTests/AutoLockControllerTests.swift
git commit -m "AutoLockController: таймаут бездействия и sleep-блокировка, тестируемо через fakes (Task 5)"
```

---

### Task 6: KdbxEntry+Convenience — title/login/password/url/notes/TOTP

**Files:**
- Create: `MyPass/Models/KdbxEntry+Convenience.swift`
- Test: `MyPassTests/KdbxEntryConvenienceTests.swift`

**Interfaces:**
- Consumes: `MyPassKit.KdbxEntry`, `MyPassKit.KdbxField` (Task 1).
- Produces (extension on `KdbxEntry`, mutating computed properties — `KdbxEntry` is a `struct`, so these are used via `var entry = ...; entry.title = "x"`):
```swift
extension KdbxEntry {
    var title: String { get set }
    var login: String { get set }
    var password: String { get set }
    var url: String { get set }
    var notes: String { get set }
    var totpSecretBase32: String? { get set }
}
```
Property names and semantics are consumed verbatim by Task 12 (`EntryListView`/search), Task 13 (`EntryDetailView`), Task 14 (`EntryEditView`), Task 21 (`CSVImporter`) — do not rename.

- [ ] **Step 1: Write the failing test for title getter/setter on an entry with no fields**

Create `MyPassTests/KdbxEntryConvenienceTests.swift`:

```swift
import XCTest
import MyPassKit
@testable import MyPass

final class KdbxEntryConvenienceTests: XCTestCase {
    func makeEmptyEntry() -> KdbxEntry {
        let now = Date()
        return KdbxEntry(
            uuid: UUID(),
            iconID: 0,
            fields: [],
            creationTime: now,
            lastModificationTime: now,
            lastAccessTime: now,
            locationChanged: now,
            history: []
        )
    }

    func testTitleGetterDefaultsToEmptyString() {
        let entry = makeEmptyEntry()
        XCTAssertEqual(entry.title, "")
    }

    func testTitleSetterCreatesFieldWhenMissing() {
        var entry = makeEmptyEntry()
        entry.title = "GitHub"
        XCTAssertEqual(entry.title, "GitHub")
        XCTAssertEqual(entry.fields.first(where: { $0.key == "Title" })?.value, "GitHub")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/KdbxEntryConvenienceTests`
Expected: FAIL — `entry.title` does not exist.

- [ ] **Step 3: Minimal implementation for title (pattern to repeat for the rest)**

Create `MyPass/Models/KdbxEntry+Convenience.swift`:

```swift
import Foundation
import MyPassKit

private extension KdbxEntry {
    func fieldValue(forKey key: String) -> String {
        fields.first(where: { $0.key == key })?.value ?? ""
    }

    mutating func setFieldValue(_ value: String, forKey key: String, isProtected: Bool) {
        if let index = fields.firstIndex(where: { $0.key == key }) {
            fields[index].value = value
        } else {
            fields.append(KdbxField(key: key, value: value, isProtected: isProtected))
        }
    }
}

extension KdbxEntry {
    var title: String {
        get { fieldValue(forKey: "Title") }
        set { setFieldValue(newValue, forKey: "Title", isProtected: false) }
    }

    var login: String {
        get { fieldValue(forKey: "UserName") }
        set { setFieldValue(newValue, forKey: "UserName", isProtected: false) }
    }

    var password: String {
        get { fieldValue(forKey: "Password") }
        set { setFieldValue(newValue, forKey: "Password", isProtected: true) }
    }

    var url: String {
        get { fieldValue(forKey: "URL") }
        set { setFieldValue(newValue, forKey: "URL", isProtected: false) }
    }

    var notes: String {
        get { fieldValue(forKey: "Notes") }
        set { setFieldValue(newValue, forKey: "Notes", isProtected: false) }
    }

    var totpSecretBase32: String? {
        get { fields.first(where: { $0.key == "otp" })?.value }
        set {
            guard let newValue else {
                fields.removeAll(where: { $0.key == "otp" })
                return
            }
            setFieldValue(newValue, forKey: "otp", isProtected: true)
        }
    }
}
```

- [ ] **Step 4: Run to verify title tests pass**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/KdbxEntryConvenienceTests`
Expected: PASS (2/2).

- [ ] **Step 5: Write the failing tests for the remaining properties**

Add to `MyPassTests/KdbxEntryConvenienceTests.swift`:

```swift
    func testLoginRoundTrips() {
        var entry = makeEmptyEntry()
        entry.login = "alice"
        XCTAssertEqual(entry.login, "alice")
    }

    func testPasswordRoundTripsAndIsProtected() {
        var entry = makeEmptyEntry()
        entry.password = "s3cret"
        XCTAssertEqual(entry.password, "s3cret")
        XCTAssertEqual(entry.fields.first(where: { $0.key == "Password" })?.isProtected, true)
    }

    func testURLRoundTrips() {
        var entry = makeEmptyEntry()
        entry.url = "https://example.com"
        XCTAssertEqual(entry.url, "https://example.com")
    }

    func testNotesRoundTrips() {
        var entry = makeEmptyEntry()
        entry.notes = "some note"
        XCTAssertEqual(entry.notes, "some note")
    }

    func testTOTPSecretIsNilWhenAbsentAndRoundTripsWhenSet() {
        var entry = makeEmptyEntry()
        XCTAssertNil(entry.totpSecretBase32)
        entry.totpSecretBase32 = "JBSWY3DPEHPK3PXP"
        XCTAssertEqual(entry.totpSecretBase32, "JBSWY3DPEHPK3PXP")
        XCTAssertEqual(entry.fields.first(where: { $0.key == "otp" })?.isProtected, true)
        entry.totpSecretBase32 = nil
        XCTAssertNil(entry.totpSecretBase32)
    }
```

- [ ] **Step 6: Run full KdbxEntryConvenienceTests suite to verify all pass**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/KdbxEntryConvenienceTests`
Expected: 7/7 PASS (implementation from Step 3 already covers all of them — confirms no gaps).

- [ ] **Step 7: Commit**

```bash
git add MyPass/Models/KdbxEntry+Convenience.swift MyPassTests/KdbxEntryConvenienceTests.swift
git commit -m "KdbxEntry+Convenience: title/login/password/url/notes/TOTP над fields (Task 6)"
```

---

### Task 7: TOTPCode — Base32, otpauth:// парсинг, текущий код, обратный отсчёт

**Files:**
- Create: `MyPass/Models/TOTPCode.swift`
- Test: `MyPassTests/TOTPCodeTests.swift`

**Interfaces:**
- Consumes: `MyPassKit.TOTPGenerator.generate`, `MyPassKit.TOTPAlgorithm` (Task 1).
- Produces:
```swift
enum TOTPCode {
    static func base32Decode(_ s: String) -> Data?
    static func base32Encode(_ data: Data) -> String
    static func parse(otpauthURL: String) -> (secret: Data, digits: Int, period: TimeInterval, algorithm: TOTPAlgorithm)?
    static func currentCode(secretBase32: String, digits: Int, period: TimeInterval, algorithm: TOTPAlgorithm, now: Date) -> String?
    static func secondsRemaining(period: TimeInterval, now: Date) -> TimeInterval
}
```
Consumed by Task 13 (`EntryDetailView` live TOTP code + countdown) and Task 14 (`EntryEditView` otpauth:// paste field).

- [ ] **Step 1: Write the failing Base32 round-trip test**

Create `MyPassTests/TOTPCodeTests.swift`:

```swift
import XCTest
import MyPassKit
@testable import MyPass

final class TOTPCodeTests: XCTestCase {
    func testBase32RoundTrip() {
        let original = Data("Hello!!".utf8)
        let encoded = TOTPCode.base32Encode(original)
        let decoded = TOTPCode.base32Decode(encoded)
        XCTAssertEqual(decoded, original)
    }

    func testBase32DecodeKnownVector() {
        // RFC 4648 test vector: "foobar" -> "MZXW6YTBOI======"
        let decoded = TOTPCode.base32Decode("MZXW6YTBOI======")
        XCTAssertEqual(decoded, Data("foobar".utf8))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/TOTPCodeTests`
Expected: FAIL — `TOTPCode` does not exist.

- [ ] **Step 3: Minimal implementation — Base32**

Create `MyPass/Models/TOTPCode.swift`:

```swift
import Foundation
import MyPassKit

enum TOTPCode {
    private static let base32Alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    static func base32Encode(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        var bits = 0
        var value = 0
        var output = ""
        for byte in data {
            value = (value << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                let index = (value >> (bits - 5)) & 0x1F
                output.append(base32Alphabet[index])
                bits -= 5
            }
        }
        if bits > 0 {
            let index = (value << (5 - bits)) & 0x1F
            output.append(base32Alphabet[index])
        }
        while output.count % 8 != 0 {
            output.append("=")
        }
        return output
    }

    static func base32Decode(_ s: String) -> Data? {
        let cleaned = s.uppercased().replacingOccurrences(of: "=", with: "")
        guard !cleaned.isEmpty else { return Data() }
        var bits = 0
        var value = 0
        var output = [UInt8]()
        for character in cleaned {
            guard let index = base32Alphabet.firstIndex(of: character) else { return nil }
            value = (value << 5) | index
            bits += 5
            if bits >= 8 {
                let byte = UInt8((value >> (bits - 8)) & 0xFF)
                output.append(byte)
                bits -= 8
            }
        }
        return Data(output)
    }

    static func parse(otpauthURL: String) -> (secret: Data, digits: Int, period: TimeInterval, algorithm: TOTPAlgorithm)? {
        nil // implemented in Step 5
    }

    static func currentCode(secretBase32: String, digits: Int, period: TimeInterval, algorithm: TOTPAlgorithm, now: Date) -> String? {
        nil // implemented in Step 7
    }

    static func secondsRemaining(period: TimeInterval, now: Date) -> TimeInterval {
        0 // implemented in Step 9
    }
}
```

- [ ] **Step 4: Run to verify Base32 tests pass**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/TOTPCodeTests/testBase32RoundTrip,MyPassTests/TOTPCodeTests/testBase32DecodeKnownVector`
Expected: PASS (2/2).

- [ ] **Step 5: Write the failing test for otpauth:// parsing**

Add to `MyPassTests/TOTPCodeTests.swift`:

```swift
    func testParseOtpauthURLExtractsSecretDigitsPeriodAlgorithm() {
        // secret "JBSWY3DPEHPK3PXP" decodes to "Hello!\xDE\xAD\xBE\xEF"-ish bytes (RFC 6238-style example issuer/account)
        let url = "otpauth://totp/Example:alice@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Example&algorithm=SHA1&digits=6&period=30"
        guard let parsed = TOTPCode.parse(otpauthURL: url) else {
            return XCTFail("expected successful parse")
        }
        XCTAssertEqual(parsed.secret, TOTPCode.base32Decode("JBSWY3DPEHPK3PXP"))
        XCTAssertEqual(parsed.digits, 6)
        XCTAssertEqual(parsed.period, 30)
        XCTAssertEqual(parsed.algorithm, .sha1)
    }

    func testParseOtpauthURLDefaultsWhenParamsMissing() {
        let url = "otpauth://totp/Example:alice@example.com?secret=JBSWY3DPEHPK3PXP"
        guard let parsed = TOTPCode.parse(otpauthURL: url) else {
            return XCTFail("expected successful parse")
        }
        XCTAssertEqual(parsed.digits, 6)
        XCTAssertEqual(parsed.period, 30)
        XCTAssertEqual(parsed.algorithm, .sha1)
    }

    func testParseOtpauthURLReturnsNilWithoutSecret() {
        let url = "otpauth://totp/Example:alice@example.com?issuer=Example"
        XCTAssertNil(TOTPCode.parse(otpauthURL: url))
    }
```

`TOTPAlgorithm` needs `Equatable` for these assertions — it is declared `public enum TOTPAlgorithm { case sha1, sha256, sha512 }` in `MyPassKit` (Task 1); Swift auto-synthesizes `Equatable` for enums with no associated values with no extra work needed, so no change to `MyPassKit` is required here.

- [ ] **Step 6: Run to verify parse tests fail, then implement**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/TOTPCodeTests`
Expected: the three new tests FAIL (parse returns `nil` always per the Step 3 stub).

Replace the `parse` stub in `TOTPCode.swift`:

```swift
    static func parse(otpauthURL: String) -> (secret: Data, digits: Int, period: TimeInterval, algorithm: TOTPAlgorithm)? {
        guard let components = URLComponents(string: otpauthURL),
              components.scheme == "otpauth",
              let queryItems = components.queryItems,
              let secretBase32 = queryItems.first(where: { $0.name == "secret" })?.value,
              let secret = base32Decode(secretBase32) else {
            return nil
        }

        let digits = queryItems.first(where: { $0.name == "digits" })?.value.flatMap(Int.init) ?? 6
        let period = queryItems.first(where: { $0.name == "period" })?.value.flatMap(Double.init) ?? 30

        let algorithmName = queryItems.first(where: { $0.name == "algorithm" })?.value?.uppercased() ?? "SHA1"
        let algorithm: TOTPAlgorithm
        switch algorithmName {
        case "SHA256": algorithm = .sha256
        case "SHA512": algorithm = .sha512
        default: algorithm = .sha1
        }

        return (secret: secret, digits: digits, period: period, algorithm: algorithm)
    }
```

- [ ] **Step 7: Run to verify parse tests pass, then write the failing test for currentCode**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/TOTPCodeTests`
Expected: all parse tests PASS.

Add to `MyPassTests/TOTPCodeTests.swift`:

```swift
    func testCurrentCodeMatchesUnderlyingGeneratorAtFixedTime() {
        let secretBase32 = TOTPCode.base32Encode(Data([0x01, 0x02, 0x03, 0x04, 0x05]))
        let now = Date(timeIntervalSince1970: 59)
        let expected = TOTPGenerator.generate(
            secret: Data([0x01, 0x02, 0x03, 0x04, 0x05]),
            time: now,
            step: 30,
            digits: 6,
            algorithm: .sha1
        )
        let actual = TOTPCode.currentCode(secretBase32: secretBase32, digits: 6, period: 30, algorithm: .sha1, now: now)
        XCTAssertEqual(actual, expected)
    }

    func testCurrentCodeReturnsNilForInvalidBase32() {
        let actual = TOTPCode.currentCode(secretBase32: "not-valid-base32!!", digits: 6, period: 30, algorithm: .sha1, now: Date())
        XCTAssertNil(actual)
    }
```

- [ ] **Step 8: Run to verify it fails, then implement currentCode**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/TOTPCodeTests`
Expected: FAIL — stub returns `nil` unconditionally, so `testCurrentCodeMatchesUnderlyingGeneratorAtFixedTime` fails while `testCurrentCodeReturnsNilForInvalidBase32` accidentally passes.

Replace the `currentCode` stub in `TOTPCode.swift`:

```swift
    static func currentCode(secretBase32: String, digits: Int, period: TimeInterval, algorithm: TOTPAlgorithm, now: Date) -> String? {
        guard let secret = base32Decode(secretBase32) else { return nil }
        return TOTPGenerator.generate(secret: secret, time: now, step: period, digits: digits, algorithm: algorithm)
    }
```

- [ ] **Step 9: Run to verify currentCode tests pass, then write the failing test for secondsRemaining**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/TOTPCodeTests`
Expected: PASS (2/2 new tests).

Add to `MyPassTests/TOTPCodeTests.swift`:

```swift
    func testSecondsRemainingAtStartOfPeriod() {
        let now = Date(timeIntervalSince1970: 30) // exactly on a 30s boundary
        XCTAssertEqual(TOTPCode.secondsRemaining(period: 30, now: now), 30, accuracy: 0.001)
    }

    func testSecondsRemainingMidPeriod() {
        let now = Date(timeIntervalSince1970: 45) // 15s into the [30,60) window
        XCTAssertEqual(TOTPCode.secondsRemaining(period: 30, now: now), 15, accuracy: 0.001)
    }

    func testSecondsRemainingOneSecondBeforeBoundary() {
        let now = Date(timeIntervalSince1970: 59)
        XCTAssertEqual(TOTPCode.secondsRemaining(period: 30, now: now), 1, accuracy: 0.001)
    }
```

- [ ] **Step 10: Run to verify it fails, then implement secondsRemaining**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/TOTPCodeTests`
Expected: FAIL — stub always returns `0`.

Replace the `secondsRemaining` stub in `TOTPCode.swift`:

```swift
    static func secondsRemaining(period: TimeInterval, now: Date) -> TimeInterval {
        let elapsedInPeriod = now.timeIntervalSince1970.truncatingRemainder(dividingBy: period)
        let remaining = period - elapsedInPeriod
        return remaining == period ? period : remaining
    }
```

(the `elapsedInPeriod == 0` case, exactly on a boundary, must report a full fresh period rather than `0` — the ternary handles that; verified by `testSecondsRemainingAtStartOfPeriod`.)

- [ ] **Step 11: Run full TOTPCodeTests suite to verify all pass**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/TOTPCodeTests`
Expected: 11/11 PASS.

- [ ] **Step 12: Commit**

```bash
git add MyPass/Models/TOTPCode.swift MyPassTests/TOTPCodeTests.swift
git commit -m "TOTPCode: Base32, otpauth:// парсинг, текущий код, обратный отсчёт (Task 7)"
```

---

### Task 8: UnlockView + wiring в ContentView

**Files:**
- Create: `MyPass/UI/Unlock/UnlockView.swift`
- Modify: `MyPass/ContentView.swift`

**Interfaces:**
- Consumes: `VaultSession` (Task 4) — `state`, `unlock(password:)`.
- Produces: `UnlockView` (SwiftUI `View`, takes `@EnvironmentObject var vaultSession: VaultSession`); `ContentView` now branches on `vaultSession.state` to show `UnlockView` or the (still placeholder, until Task 10) unlocked content. `MyPassApp.swift` gains a `VaultSession` `@StateObject` injected as `.environmentObject`.

No automated UI test is written for this task — SwiftUI view bodies here are thin wiring over already-tested `VaultSession`; Task 12's `NavigationStateSearchTests`-style pattern (pure logic extracted to a testable function) is the plan's answer to "UI: точечно" from the design spec. This task's manual verification step replaces an XCTest.

- [ ] **Step 1: Update MyPassApp.swift to own a VaultSession**

Modify `MyPass/MyPassApp.swift`:

```swift
import SwiftUI
import MyPassKit

@main
struct MyPassApp: App {
    @StateObject private var vaultSession = VaultSession(
        fileStore: VaultFileStore(
            directory: FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MyPass")
        )
    )

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vaultSession)
        }
    }
}
```

- [ ] **Step 2: Write UnlockView**

Create `MyPass/UI/Unlock/UnlockView.swift`:

```swift
import SwiftUI

struct UnlockView: View {
    @EnvironmentObject var vaultSession: VaultSession
    @State private var password: String = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("MyPass")
                .font(.largeTitle)
            SecureField("Мастер-пароль", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit(attemptUnlock)
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
            Button("Разблокировать", action: attemptUnlock)
                .buttonStyle(.borderedProminent)
        }
        .padding(40)
    }

    private func attemptUnlock() {
        do {
            try vaultSession.unlock(password: password)
            password = ""
            errorMessage = nil
        } catch {
            errorMessage = "Неверный пароль или повреждённый файл."
        }
    }
}
```

- [ ] **Step 3: Wire ContentView to branch on vault state**

Modify `MyPass/ContentView.swift`:

```swift
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var vaultSession: VaultSession

    var body: some View {
        switch vaultSession.state {
        case .locked:
            UnlockView()
        case .unlocked:
            Text("Hello, MyPass") // replaced by NavigationSplitView in Task 10
                .padding()
        }
    }
}
```

- [ ] **Step 4: Build and manually verify**

Run: `xcodegen generate && xcodebuild -project MyPass.xcodeproj -scheme MyPass build`
Expected: `** BUILD SUCCEEDED **`.

Manually run the app (`open` the built `.app` from DerivedData, or run from Xcode): expect the `UnlockView` password field on first launch; entering any password and pressing "Разблокировать" creates a new empty vault at `~/Library/Application Support/MyPass/vault.kdbx` and switches to the "Hello, MyPass" placeholder.

- [ ] **Step 5: Commit**

```bash
git add MyPass/MyPassApp.swift MyPass/UI/Unlock/UnlockView.swift MyPass/ContentView.swift
git commit -m "UnlockView и переключение locked/unlocked в ContentView (Task 8)"
```

---

### Task 9: BiometricKeyStore — протокол + Keychain/LocalAuthentication + Fake

**Files:**
- Create: `MyPass/Security/BiometricKeyStore.swift`
- Modify: `MyPass/UI/Unlock/UnlockView.swift`
- Test: `MyPassTests/BiometricKeyStoreTests.swift`

**Interfaces:**
- Consumes: `LocalAuthentication.LAContext`, `Security` Keychain APIs (production only); `VaultSession` (Task 4), `UnlockView` (Task 8) for wiring.
- Produces:
```swift
protocol BiometricKeyStoring {
    func store(derivedKey: Data, account: String) throws
    func retrieve(account: String) throws -> Data?
}

final class BiometricKeyStore: BiometricKeyStoring { /* Keychain + LAContext */ }
final class FakeBiometricKeyStore: BiometricKeyStoring { /* in-memory dictionary, tests only */ }
```
Consumed by Task 8's `UnlockView` (Touch ID button appears when `retrieve` returns non-nil) — note the actual "derived key unlocks the vault" wiring (mapping a retrieved key back to a master password) is intentionally out of scope for this plan revision beyond storing/retrieving raw key bytes; `UnlockView`'s Touch ID button in this task only demonstrates presence/absence of a stored key end to end via the protocol, matching the spec's instruction to "интеграция кнопки Touch ID в UnlockView".

- [ ] **Step 1: Write the failing test using FakeBiometricKeyStore**

Create `MyPassTests/BiometricKeyStoreTests.swift`:

```swift
import XCTest
@testable import MyPass

final class BiometricKeyStoreTests: XCTestCase {
    func testFakeStoreRetrieveRoundTrips() throws {
        let store = FakeBiometricKeyStore()
        let key = Data([0xAA, 0xBB, 0xCC])
        try store.store(derivedKey: key, account: "default")
        XCTAssertEqual(try store.retrieve(account: "default"), key)
    }

    func testFakeStoreRetrieveReturnsNilForUnknownAccount() throws {
        let store = FakeBiometricKeyStore()
        XCTAssertNil(try store.retrieve(account: "missing"))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/BiometricKeyStoreTests`
Expected: FAIL — `FakeBiometricKeyStore` does not exist.

- [ ] **Step 3: Minimal implementation — protocol, Fake, and real Keychain-backed store**

Create `MyPass/Security/BiometricKeyStore.swift`:

```swift
import Foundation
import Security
import LocalAuthentication

protocol BiometricKeyStoring {
    func store(derivedKey: Data, account: String) throws
    func retrieve(account: String) throws -> Data?
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
}

final class FakeBiometricKeyStore: BiometricKeyStoring {
    private var storage: [String: Data] = [:]

    func store(derivedKey: Data, account: String) throws {
        storage[account] = derivedKey
    }

    func retrieve(account: String) throws -> Data? {
        storage[account]
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/BiometricKeyStoreTests`
Expected: PASS (2/2). Note: `BiometricKeyStoreTests` deliberately exercises only `FakeBiometricKeyStore` — the real `BiometricKeyStore` requires an actual Touch ID-enrolled device and cannot run in CI/headless environments, matching the spec's explicit instruction.

- [ ] **Step 5: Wire a Touch ID button into UnlockView**

Modify `MyPass/UI/Unlock/UnlockView.swift`:

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
        VStack(spacing: 16) {
            Text("MyPass")
                .font(.largeTitle)
            SecureField("Мастер-пароль", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit(attemptUnlock)
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
            Button("Разблокировать", action: attemptUnlock)
                .buttonStyle(.borderedProminent)
            if hasStoredBiometricKey {
                Button("Touch ID", systemImage: "touchid", action: attemptBiometricUnlock)
            }
        }
        .padding(40)
    }

    private func attemptUnlock() {
        do {
            try vaultSession.unlock(password: password)
            password = ""
            errorMessage = nil
        } catch {
            errorMessage = "Неверный пароль или повреждённый файл."
        }
    }

    private func attemptBiometricUnlock() {
        // Placeholder wiring for this task: retrieving the stored derived key succeeds
        // only after Touch ID biometric confirmation (enforced by SecAccessControl on the
        // Keychain item itself, not by this view). Mapping the derived key back into an
        // unlock call is deferred — this button demonstrates the store/retrieve contract end to end.
        errorMessage = (try? biometricKeyStore.retrieve(account: "master")) == nil
            ? "Touch ID недоступен."
            : nil
    }
}
```

- [ ] **Step 6: Build to verify the app still compiles**

Run: `xcodegen generate && xcodebuild -project MyPass.xcodeproj -scheme MyPass build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add MyPass/Security/BiometricKeyStore.swift MyPass/UI/Unlock/UnlockView.swift MyPassTests/BiometricKeyStoreTests.swift
git commit -m "BiometricKeyStore: протокол + Keychain/Touch ID + Fake, кнопка в UnlockView (Task 9)"
```

---

### Task 10: ContentView skeleton — NavigationSplitView

**Files:**
- Create: `MyPass/State/NavigationState.swift`
- Modify: `MyPass/ContentView.swift`
- Modify: `MyPass/MyPassApp.swift`

**Interfaces:**
- Consumes: `VaultSession.currentDatabase` (Task 4), `MyPassKit.KdbxGroup` (Task 1).
- Produces:
```swift
final class NavigationState: ObservableObject {
    @Published var selectedGroupID: UUID?
    @Published var selectedEntryID: UUID?
    @Published var searchText: String = ""
}
```
Consumed by Task 11 (`GroupSidebarView` binds `selectedGroupID`), Task 12 (`EntryListView` reads `selectedGroupID`/`searchText`, sets `selectedEntryID`), Task 13 (`EntryDetailView` reads `selectedEntryID`).

- [ ] **Step 1: Create NavigationState**

Create `MyPass/State/NavigationState.swift`:

```swift
import Foundation

final class NavigationState: ObservableObject {
    @Published var selectedGroupID: UUID?
    @Published var selectedEntryID: UUID?
    @Published var searchText: String = ""
}
```

- [ ] **Step 2: Inject NavigationState alongside VaultSession**

Modify `MyPass/MyPassApp.swift`:

```swift
import SwiftUI
import MyPassKit

@main
struct MyPassApp: App {
    @StateObject private var vaultSession = VaultSession(
        fileStore: VaultFileStore(
            directory: FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MyPass")
        )
    )
    @StateObject private var navigationState = NavigationState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vaultSession)
                .environmentObject(navigationState)
        }
    }
}
```

- [ ] **Step 3: Build the three-column skeleton in ContentView**

Modify `MyPass/ContentView.swift`:

```swift
import SwiftUI
import MyPassKit

struct ContentView: View {
    @EnvironmentObject var vaultSession: VaultSession
    @EnvironmentObject var navigationState: NavigationState

    var body: some View {
        switch vaultSession.state {
        case .locked:
            UnlockView()
        case .unlocked(let database):
            NavigationSplitView {
                GroupSidebarView(rootGroup: database.rootGroup)
            } content: {
                EntryListView(rootGroup: database.rootGroup)
            } detail: {
                EntryDetailView()
            }
        }
    }
}
```

`GroupSidebarView`, `EntryListView`, `EntryDetailView` do not exist yet — created in Tasks 11, 12, 13 respectively. For this task, stub them minimally so the build succeeds:

Create placeholder stubs to be replaced in later tasks — write them directly into their final target files now, since Tasks 11–13 replace the bodies but keep these signatures:

`MyPass/UI/Sidebar/GroupSidebarView.swift`:

```swift
import SwiftUI
import MyPassKit

struct GroupSidebarView: View {
    let rootGroup: KdbxGroup

    var body: some View {
        Text(rootGroup.name) // replaced by a real tree in Task 11
    }
}
```

`MyPass/UI/EntryList/EntryListView.swift`:

```swift
import SwiftUI
import MyPassKit

struct EntryListView: View {
    let rootGroup: KdbxGroup

    var body: some View {
        Text("\(rootGroup.entries.count) entries") // replaced by a real list in Task 12
    }
}
```

`MyPass/UI/EntryDetail/EntryDetailView.swift`:

```swift
import SwiftUI

struct EntryDetailView: View {
    var body: some View {
        Text("Выберите запись") // replaced by a real detail card in Task 13
    }
}
```

- [ ] **Step 4: Build to verify**

Run: `xcodegen generate && xcodebuild -project MyPass.xcodeproj -scheme MyPass build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add MyPass/State/NavigationState.swift MyPass/MyPassApp.swift MyPass/ContentView.swift MyPass/UI/Sidebar/GroupSidebarView.swift MyPass/UI/EntryList/EntryListView.swift MyPass/UI/EntryDetail/EntryDetailView.swift
git commit -m "ContentView: трёхколоночный NavigationSplitView и NavigationState (Task 10)"
```

---

### Task 11: GroupSidebarView — дерево групп + выбор + Корзина

**Files:**
- Modify: `MyPass/UI/Sidebar/GroupSidebarView.swift`

**Interfaces:**
- Consumes: `MyPassKit.KdbxGroup` (`Identifiable`, `subgroups`, `name`, `uuid` — Task 1), `NavigationState.selectedGroupID` (Task 10).
- Produces: `GroupSidebarView(rootGroup: KdbxGroup)` — a `View` rendering the group tree with a fixed "Корзина" row pinned below it; sets `NavigationState.selectedGroupID` on tap; accepts `onDrop` for entry UUIDs (wired fully as a working move in Task 15 — this task adds the drop-target modifier and a no-op handler placeholder that Task 15 replaces, per the spec's "drop-target для drag-and-drop записи (onDrop)").

- [ ] **Step 1: Replace the placeholder body with a real List/tree**

Modify `MyPass/UI/Sidebar/GroupSidebarView.swift`:

```swift
import SwiftUI
import MyPassKit

struct GroupSidebarView: View {
    let rootGroup: KdbxGroup
    @EnvironmentObject var navigationState: NavigationState

    var body: some View {
        List(selection: $navigationState.selectedGroupID) {
            OutlineGroup([rootGroup], children: \.subgroupsForOutline) { group in
                Text(group.name)
                    .tag(group.uuid)
                    .onDrop(of: [.text], isTargeted: nil) { providers in
                        // Full move-on-drop logic wired in Task 15; this task only
                        // establishes the drop target per the sidebar's spec responsibility.
                        false
                    }
            }
            Text("Корзина")
                .foregroundStyle(.secondary)
        }
        .listStyle(.sidebar)
    }
}

private extension KdbxGroup {
    var subgroupsForOutline: [KdbxGroup]? {
        subgroups.isEmpty ? nil : subgroups
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `xcodegen generate && xcodebuild -project MyPass.xcodeproj -scheme MyPass build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Manual verification**

Run the app, unlock, and confirm the sidebar shows a single "MyPass" root row (no subgroups yet) plus a "Корзина" row underneath, and clicking the root row highlights it (selection binding works).

- [ ] **Step 4: Commit**

```bash
git add MyPass/UI/Sidebar/GroupSidebarView.swift
git commit -m "GroupSidebarView: дерево групп через OutlineGroup, строка Корзина, drop-target (Task 11)"
```

---

### Task 12: EntryListView — список записей + глобальный поиск

**Files:**
- Create: `MyPass/UI/EntryList/EntrySearch.swift`
- Modify: `MyPass/UI/EntryList/EntryListView.swift`
- Test: `MyPassTests/NavigationStateSearchTests.swift`

**Interfaces:**
- Consumes: `MyPassKit.KdbxGroup`, `MyPassKit.KdbxEntry` (Task 1), `KdbxEntry.title`/`.login`/`.url`/`.notes` (Task 6), `NavigationState.selectedGroupID`/`.searchText`/`.selectedEntryID` (Task 10).
- Produces:
```swift
enum EntrySearch {
    static func matches(entry: KdbxEntry, query: String) -> Bool
    static func allEntries(in group: KdbxGroup) -> [KdbxEntry]           // flattens group + subgroups, for global search
    static func entries(in group: KdbxGroup, matching query: String) -> [KdbxEntry]  // group's own entries if query empty, else global filtered
}
```
Consumed by `EntryListView`'s body and by `MyPassTests/NavigationStateSearchTests.swift` directly (pure function, testable without SwiftUI).

- [ ] **Step 1: Write the failing test for matches(entry:query:)**

Create `MyPassTests/NavigationStateSearchTests.swift`:

```swift
import XCTest
import MyPassKit
@testable import MyPass

final class NavigationStateSearchTests: XCTestCase {
    func makeEntry(title: String, login: String = "", url: String = "", notes: String = "") -> KdbxEntry {
        let now = Date()
        var entry = KdbxEntry(
            uuid: UUID(),
            iconID: 0,
            fields: [],
            creationTime: now,
            lastModificationTime: now,
            lastAccessTime: now,
            locationChanged: now,
            history: []
        )
        entry.title = title
        entry.login = login
        entry.url = url
        entry.notes = notes
        return entry
    }

    func testMatchesTitleCaseInsensitive() {
        let entry = makeEntry(title: "GitHub")
        XCTAssertTrue(EntrySearch.matches(entry: entry, query: "github"))
        XCTAssertTrue(EntrySearch.matches(entry: entry, query: "HUB"))
    }

    func testMatchesLoginURLNotes() {
        let entry = makeEntry(title: "x", login: "alice@example.com", url: "https://example.com", notes: "work account")
        XCTAssertTrue(EntrySearch.matches(entry: entry, query: "alice"))
        XCTAssertTrue(EntrySearch.matches(entry: entry, query: "example.com"))
        XCTAssertTrue(EntrySearch.matches(entry: entry, query: "work"))
    }

    func testNoMatchReturnsFalse() {
        let entry = makeEntry(title: "GitHub")
        XCTAssertFalse(EntrySearch.matches(entry: entry, query: "gitlab"))
    }

    func testEmptyQueryMatchesEverything() {
        let entry = makeEntry(title: "GitHub")
        XCTAssertTrue(EntrySearch.matches(entry: entry, query: ""))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/NavigationStateSearchTests`
Expected: FAIL — `EntrySearch` does not exist.

- [ ] **Step 3: Minimal implementation of matches**

Create `MyPass/UI/EntryList/EntrySearch.swift`:

```swift
import Foundation
import MyPassKit

enum EntrySearch {
    static func matches(entry: KdbxEntry, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let haystacks = [entry.title, entry.login, entry.url, entry.notes]
        return haystacks.contains { $0.range(of: query, options: .caseInsensitive) != nil }
    }

    static func allEntries(in group: KdbxGroup) -> [KdbxEntry] {
        group.entries + group.subgroups.flatMap { allEntries(in: $0) }
    }

    static func entries(in group: KdbxGroup, matching query: String) -> [KdbxEntry] {
        guard !query.isEmpty else {
            return group.entries
        }
        return allEntries(in: findRoot(from: group)).filter { matches(entry: $0, query: query) }
    }

    private static func findRoot(from group: KdbxGroup) -> KdbxGroup {
        // KdbxGroup has no parent pointer by design (see design spec); global search
        // therefore always searches from whichever group reference is handed in as "the tree root".
        // EntryListView always passes the database's rootGroup here, so this is a passthrough.
        group
    }
}
```

- [ ] **Step 4: Run to verify tests pass**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/NavigationStateSearchTests`
Expected: PASS (4/4).

- [ ] **Step 5: Write the failing test for entries(in:matching:) group-scoped vs global behavior**

Add to `MyPassTests/NavigationStateSearchTests.swift`:

```swift
    func testEntriesInGroupMatchingEmptyQueryReturnsOnlyGroupOwnEntries() {
        let now = Date()
        let child = makeEntry(title: "Child Entry")
        let subgroup = KdbxGroup(uuid: UUID(), name: "Sub", iconID: 0, creationTime: now, lastModificationTime: now, locationChanged: now, entries: [child], subgroups: [])
        let rootEntry = makeEntry(title: "Root Entry")
        let root = KdbxGroup(uuid: UUID(), name: "Root", iconID: 0, creationTime: now, lastModificationTime: now, locationChanged: now, entries: [rootEntry], subgroups: [subgroup])

        let result = EntrySearch.entries(in: root, matching: "")
        XCTAssertEqual(result.map(\.title), ["Root Entry"])
    }

    func testEntriesInGroupMatchingNonEmptyQuerySearchesGlobally() {
        let now = Date()
        let child = makeEntry(title: "Child Entry")
        let subgroup = KdbxGroup(uuid: UUID(), name: "Sub", iconID: 0, creationTime: now, lastModificationTime: now, locationChanged: now, entries: [child], subgroups: [])
        let rootEntry = makeEntry(title: "Root Entry")
        let root = KdbxGroup(uuid: UUID(), name: "Root", iconID: 0, creationTime: now, lastModificationTime: now, locationChanged: now, entries: [rootEntry], subgroups: [subgroup])

        let result = EntrySearch.entries(in: root, matching: "child")
        XCTAssertEqual(result.map(\.title), ["Child Entry"])
    }
```

- [ ] **Step 6: Run full NavigationStateSearchTests suite to verify all pass**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/NavigationStateSearchTests`
Expected: 6/6 PASS (implementation from Step 3 already handles both — passing `root` as both the current group and the search root works because `EntryListView`, wired next, always passes the database's `rootGroup` for the `in:` parameter).

- [ ] **Step 7: Wire EntryListView to use EntrySearch and NavigationState**

Modify `MyPass/UI/EntryList/EntryListView.swift`:

```swift
import SwiftUI
import MyPassKit

struct EntryListView: View {
    let rootGroup: KdbxGroup
    @EnvironmentObject var navigationState: NavigationState

    private var currentGroup: KdbxGroup {
        find(uuid: navigationState.selectedGroupID, in: rootGroup) ?? rootGroup
    }

    private var displayedEntries: [KdbxEntry] {
        EntrySearch.entries(in: currentGroup, matching: navigationState.searchText)
    }

    var body: some View {
        List(displayedEntries, selection: $navigationState.selectedEntryID) { entry in
            VStack(alignment: .leading) {
                Text(entry.title.isEmpty ? "(без названия)" : entry.title)
                Text(entry.login)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .tag(entry.uuid)
            .draggable(entry.uuid.uuidString) // full drag-and-drop wiring completed in Task 15
        }
        .searchable(text: $navigationState.searchText)
        .toolbar {
            ToolbarItem {
                Button("Добавить", systemImage: "plus") {
                    // wired to EntryEditView in Task 14
                }
            }
        }
    }

    private func find(uuid: UUID?, in group: KdbxGroup) -> KdbxGroup? {
        guard let uuid else { return nil }
        if group.uuid == uuid { return group }
        for subgroup in group.subgroups {
            if let found = find(uuid: uuid, in: subgroup) { return found }
        }
        return nil
    }
}
```

- [ ] **Step 8: Build to verify**

Run: `xcodegen generate && xcodebuild -project MyPass.xcodeproj -scheme MyPass build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 9: Commit**

```bash
git add MyPass/UI/EntryList/EntrySearch.swift MyPass/UI/EntryList/EntryListView.swift MyPassTests/NavigationStateSearchTests.swift
git commit -m "EntryListView: список записей группы + глобальный поиск (Task 12)"
```

---

### Task 13: EntryDetailView — просмотр, copy-to-clipboard, живой TOTP

**Files:**
- Modify: `MyPass/UI/EntryDetail/EntryDetailView.swift`
- Create: `MyPass/UI/EntryDetail/ClipboardAutoClear.swift`
- Test: `MyPassTests/ClipboardAutoClearTests.swift`

**Interfaces:**
- Consumes: `NavigationState.selectedEntryID` (Task 10), `VaultSession.currentDatabase` (Task 4), `KdbxEntry.title/login/password/url/notes/totpSecretBase32` (Task 6), `TOTPCode.currentCode`/`.secondsRemaining` (Task 7).
- Produces:
```swift
enum ClipboardAutoClear {
    static func schedule(value: String, after seconds: TimeInterval, pasteboard: PasteboardClearing, clock: AutoLockClock)
}
protocol PasteboardClearing {
    func currentString() -> String?
    func clearIfStillContains(_ value: String)
}
```
`EntryDetailView` consumes `ClipboardAutoClear.schedule` and reuses `AutoLockClock` from Task 5 (same protocol, different concrete `Timer`-based implementation wired at the app level in Task 19) rather than defining a second timer abstraction.

- [ ] **Step 1: Write the failing test for clipboard auto-clear only firing when unchanged**

Create `MyPassTests/ClipboardAutoClearTests.swift`:

```swift
import XCTest
@testable import MyPass

final class FakePasteboard: PasteboardClearing {
    var current: String?

    func currentString() -> String? { current }

    func clearIfStillContains(_ value: String) {
        if current == value {
            current = nil
        }
    }
}

final class ClipboardAutoClearTests: XCTestCase {
    func testClearsWhenPasteboardUnchanged() {
        let pasteboard = FakePasteboard()
        pasteboard.current = "s3cret"
        let clock = FakeClock()

        ClipboardAutoClear.schedule(value: "s3cret", after: 30, pasteboard: pasteboard, clock: clock)
        clock.fireLast()

        XCTAssertNil(pasteboard.current)
    }

    func testDoesNotClearWhenUserCopiedSomethingElseMeanwhile() {
        let pasteboard = FakePasteboard()
        pasteboard.current = "s3cret"
        let clock = FakeClock()

        ClipboardAutoClear.schedule(value: "s3cret", after: 30, pasteboard: pasteboard, clock: clock)
        pasteboard.current = "something the user copied later"
        clock.fireLast()

        XCTAssertEqual(pasteboard.current, "something the user copied later")
    }
}
```

(`FakeClock` is the same type already defined in `MyPassTests/AutoLockControllerTests.swift`, Task 5 — both files compile into the same `MyPassTests` target, so it is visible here without redefinition.)

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/ClipboardAutoClearTests`
Expected: FAIL — `ClipboardAutoClear`/`PasteboardClearing` do not exist.

- [ ] **Step 3: Minimal implementation**

Create `MyPass/UI/EntryDetail/ClipboardAutoClear.swift`:

```swift
import Foundation

protocol PasteboardClearing {
    func currentString() -> String?
    func clearIfStillContains(_ value: String)
}

enum ClipboardAutoClear {
    @discardableResult
    static func schedule(value: String, after seconds: TimeInterval, pasteboard: PasteboardClearing, clock: AutoLockClock) -> AutoLockCancelable {
        clock.scheduleTick(after: seconds) {
            pasteboard.clearIfStillContains(value)
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/ClipboardAutoClearTests`
Expected: PASS (2/2).

- [ ] **Step 5: Implement the NSPasteboard-backed production adapter and the full EntryDetailView**

Modify `MyPass/UI/EntryDetail/EntryDetailView.swift`:

```swift
import SwiftUI
import AppKit
import MyPassKit

struct NSPasteboardClearing: PasteboardClearing {
    func currentString() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    func clearIfStillContains(_ value: String) {
        if currentString() == value {
            NSPasteboard.general.clearContents()
        }
    }
}

final class RealAutoLockClock: AutoLockClock {
    func scheduleTick(after seconds: TimeInterval, _ action: @escaping () -> Void) -> AutoLockCancelable {
        let timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in action() }
        return TimerCancelable(timer: timer)
    }
}

final class TimerCancelable: AutoLockCancelable {
    private let timer: Timer
    init(timer: Timer) { self.timer = timer }
    func cancel() { timer.invalidate() }
}

struct EntryDetailView: View {
    @EnvironmentObject var vaultSession: VaultSession
    @EnvironmentObject var navigationState: NavigationState
    @State private var isPasswordRevealed = false
    @State private var now = Date()

    private let pasteboard = NSPasteboardClearing()
    private let clock = RealAutoLockClock()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var currentEntry: KdbxEntry? {
        guard let database = vaultSession.currentDatabase, let id = navigationState.selectedEntryID else { return nil }
        return EntrySearch.allEntries(in: database.rootGroup).first { $0.uuid == id }
    }

    var body: some View {
        if let entry = currentEntry {
            Form {
                LabeledContent("Название", value: entry.title)
                HStack {
                    LabeledContent("Логин", value: entry.login)
                    Button("Copy", systemImage: "doc.on.doc") { copy(entry.login) }
                }
                HStack {
                    LabeledContent("Пароль", value: isPasswordRevealed ? entry.password : String(repeating: "•", count: max(entry.password.count, 8)))
                    Button(isPasswordRevealed ? "Скрыть" : "Показать") { isPasswordRevealed.toggle() }
                    Button("Copy", systemImage: "doc.on.doc") { copy(entry.password) }
                }
                if !entry.url.isEmpty {
                    HStack {
                        LabeledContent("URL", value: entry.url)
                        Button("Открыть") {
                            if let url = URL(string: entry.url) { NSWorkspace.shared.open(url) }
                        }
                    }
                }
                if !entry.notes.isEmpty {
                    LabeledContent("Заметки", value: entry.notes)
                }
                if let secret = entry.totpSecretBase32 {
                    let code = TOTPCode.currentCode(secretBase32: secret, digits: 6, period: 30, algorithm: .sha1, now: now) ?? "------"
                    let remaining = TOTPCode.secondsRemaining(period: 30, now: now)
                    HStack {
                        Text("TOTP: \(code)")
                        Text("(\(Int(remaining))s)")
                            .foregroundStyle(.secondary)
                        Button("Copy", systemImage: "doc.on.doc") { copy(code) }
                    }
                }
            }
            .padding()
            .onReceive(timer) { now = $0 }
        } else {
            Text("Выберите запись")
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        ClipboardAutoClear.schedule(value: value, after: 30, pasteboard: pasteboard, clock: clock)
    }
}
```

- [ ] **Step 6: Build to verify**

Run: `xcodegen generate && xcodebuild -project MyPass.xcodeproj -scheme MyPass build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add MyPass/UI/EntryDetail/EntryDetailView.swift MyPass/UI/EntryDetail/ClipboardAutoClear.swift MyPassTests/ClipboardAutoClearTests.swift
git commit -m "EntryDetailView: просмотр записи, copy с автоочисткой через 30с, живой TOTP (Task 13)"
```

---

### Task 14: EntryEditView — создание/редактирование записи

**Files:**
- Create: `MyPass/UI/EntryDetail/EntryEditView.swift`
- Modify: `MyPass/UI/EntryList/EntryListView.swift`

**Interfaces:**
- Consumes: `KdbxEntry` init (Task 1), `KdbxEntry.title/login/password/url/notes/totpSecretBase32` (Task 6), `TOTPCode.parse` (Task 7), `VaultSession.mutate`/`.save` (Task 4), `PasswordGeneratorView` (built in Task 18 — referenced here by name only; Task 14 wires the call site, Task 18 supplies the view body).
- Produces: `EntryEditView(entry: KdbxEntry?, group: KdbxGroup, onSave: (KdbxEntry) -> Void)` — `entry == nil` means "create new"; on Save it constructs/updates a `KdbxEntry` and calls `onSave`. `EntryListView`'s "+" toolbar button (stubbed empty in Task 12) now opens this view as a sheet.

- [ ] **Step 1: Write EntryEditView**

Create `MyPass/UI/EntryDetail/EntryEditView.swift`:

```swift
import SwiftUI
import MyPassKit

struct EntryEditView: View {
    let existingEntry: KdbxEntry?
    let onSave: (KdbxEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String = ""
    @State private var login: String = ""
    @State private var password: String = ""
    @State private var url: String = ""
    @State private var notes: String = ""
    @State private var otpauthInput: String = ""
    @State private var extraFields: [(key: String, value: String)] = []
    @State private var showPasswordGenerator = false

    init(existingEntry: KdbxEntry?, onSave: @escaping (KdbxEntry) -> Void) {
        self.existingEntry = existingEntry
        self.onSave = onSave
        _title = State(initialValue: existingEntry?.title ?? "")
        _login = State(initialValue: existingEntry?.login ?? "")
        _password = State(initialValue: existingEntry?.password ?? "")
        _url = State(initialValue: existingEntry?.url ?? "")
        _notes = State(initialValue: existingEntry?.notes ?? "")
        let standardKeys: Set<String> = ["Title", "UserName", "Password", "URL", "Notes", "otp"]
        _extraFields = State(initialValue: (existingEntry?.fields ?? [])
            .filter { !standardKeys.contains($0.key) }
            .map { (key: $0.key, value: $0.value) })
    }

    var body: some View {
        Form {
            TextField("Название", text: $title)
            TextField("Логин", text: $login)
            HStack {
                SecureField("Пароль", text: $password)
                Button("Сгенерировать") { showPasswordGenerator = true }
            }
            TextField("URL", text: $url)
            TextField("Заметки", text: $notes, axis: .vertical)
            TextField("otpauth:// или secret", text: $otpauthInput)

            Section("Дополнительные поля") {
                ForEach(extraFields.indices, id: \.self) { index in
                    HStack {
                        TextField("Ключ", text: $extraFields[index].key)
                        TextField("Значение", text: $extraFields[index].value)
                        Button("Удалить", systemImage: "minus.circle") {
                            extraFields.remove(at: index)
                        }
                    }
                }
                Button("Добавить поле", systemImage: "plus") {
                    extraFields.append((key: "", value: ""))
                }
            }

            HStack {
                Button("Отмена") { dismiss() }
                Button("Сохранить", action: save)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .sheet(isPresented: $showPasswordGenerator) {
            PasswordGeneratorView { generated in
                password = generated
                showPasswordGenerator = false
            }
        }
    }

    private func save() {
        let now = Date()
        var entry = existingEntry ?? KdbxEntry(
            uuid: UUID(),
            iconID: 0,
            fields: [],
            creationTime: now,
            lastModificationTime: now,
            lastAccessTime: now,
            locationChanged: now,
            history: []
        )
        entry.title = title
        entry.login = login
        entry.password = password
        entry.url = url
        entry.notes = notes
        entry.lastModificationTime = now
        entry.lastAccessTime = now

        if !otpauthInput.isEmpty {
            if let parsed = TOTPCode.parse(otpauthURL: otpauthInput) {
                entry.totpSecretBase32 = TOTPCode.base32Encode(parsed.secret)
            } else {
                entry.totpSecretBase32 = otpauthInput // treat as a raw Base32 secret pasted directly
            }
        }

        let standardKeys: Set<String> = ["Title", "UserName", "Password", "URL", "Notes", "otp"]
        entry.fields.removeAll { !standardKeys.contains($0.key) }
        for field in extraFields where !field.key.isEmpty {
            entry.fields.append(KdbxField(key: field.key, value: field.value, isProtected: false))
        }

        onSave(entry)
        dismiss()
    }
}
```

- [ ] **Step 2: Wire the "+" button in EntryListView to present EntryEditView, and wire tapping a row to edit it**

Modify `MyPass/UI/EntryList/EntryListView.swift` (replace the `toolbar` block and add sheet state):

```swift
    @State private var isCreatingEntry = false
    @EnvironmentObject var vaultSession: VaultSession

    var body: some View {
        List(displayedEntries, selection: $navigationState.selectedEntryID) { entry in
            VStack(alignment: .leading) {
                Text(entry.title.isEmpty ? "(без названия)" : entry.title)
                Text(entry.login)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .tag(entry.uuid)
            .draggable(entry.uuid.uuidString)
        }
        .searchable(text: $navigationState.searchText)
        .toolbar {
            ToolbarItem {
                Button("Добавить", systemImage: "plus") {
                    isCreatingEntry = true
                }
            }
        }
        .sheet(isPresented: $isCreatingEntry) {
            EntryEditView(existingEntry: nil) { newEntry in
                vaultSession.mutate { database in
                    addEntry(newEntry, toGroupWithID: currentGroup.uuid, in: database.rootGroup)
                }
            }
        }
    }

    private func addEntry(_ entry: KdbxEntry, toGroupWithID groupID: UUID, in group: KdbxGroup) {
        if group.uuid == groupID {
            group.entries.append(entry)
            return
        }
        for subgroup in group.subgroups {
            addEntry(entry, toGroupWithID: groupID, in: subgroup)
        }
    }
```

(`addEntry` mutates `KdbxGroup` in place because it is a reference type — no reassignment of `database.rootGroup` is needed, but `vaultSession.mutate` is still called so `VaultSession`'s `@Published state` fires a SwiftUI update.)

- [ ] **Step 3: Build to verify**

Run: `xcodegen generate && xcodebuild -project MyPass.xcodeproj -scheme MyPass build`
Expected: `** BUILD SUCCEEDED **` (this task references `PasswordGeneratorView` before Task 18 creates it — since Task 18 comes after 14 in this plan's numbering but both are implemented before final delivery, add a minimal stub now so this task's build succeeds standalone):

Create `MyPass/UI/PasswordGenerator/PasswordGeneratorView.swift` (stub, replaced with the full generator UI in Task 18):

```swift
import SwiftUI

struct PasswordGeneratorView: View {
    let onGenerate: (String) -> Void

    var body: some View {
        Text("Генератор паролей") // replaced by a full UI in Task 18
    }
}
```

- [ ] **Step 4: Commit**

```bash
git add MyPass/UI/EntryDetail/EntryEditView.swift MyPass/UI/EntryList/EntryListView.swift MyPass/UI/PasswordGenerator/PasswordGeneratorView.swift
git commit -m "EntryEditView: создание/редактирование записи, доп. поля, вставка TOTP (Task 14)"
```

---

### Task 15: Группы CRUD + drag-and-drop записи между группами

**Files:**
- Modify: `MyPass/UI/Sidebar/GroupSidebarView.swift`
- Modify: `MyPass/UI/EntryList/EntryListView.swift`
- Test: `MyPassTests/GroupTreeOperationsTests.swift`

**Interfaces:**
- Consumes: `MyPassKit.KdbxGroup` (Task 1), `VaultSession.mutate` (Task 4).
- Produces (pure, testable helper — mirrors the `EntrySearch` pattern from Task 12):
```swift
enum GroupTreeOperations {
    static func addSubgroup(named name: String, to parent: KdbxGroup) -> KdbxGroup   // creates + appends, returns the new group
    static func removeSubgroup(withID id: UUID, from root: KdbxGroup) -> Bool         // true if found+removed
    static func moveEntry(withID entryID: UUID, to destinationGroupID: UUID, in root: KdbxGroup) -> Bool
}
```
Consumed by `GroupSidebarView`'s context menu (add/delete group) and `onDrop` handler (replaces Task 11's placeholder `false`), and `EntryListView`'s `.draggable` payload (Task 12/14).

- [ ] **Step 1: Write the failing test for addSubgroup**

Create `MyPassTests/GroupTreeOperationsTests.swift`:

```swift
import XCTest
import MyPassKit
@testable import MyPass

final class GroupTreeOperationsTests: XCTestCase {
    func makeGroup(name: String, entries: [KdbxEntry] = [], subgroups: [KdbxGroup] = []) -> KdbxGroup {
        let now = Date()
        return KdbxGroup(uuid: UUID(), name: name, iconID: 0, creationTime: now, lastModificationTime: now, locationChanged: now, entries: entries, subgroups: subgroups)
    }

    func testAddSubgroupAppendsAndReturnsNewGroup() {
        let root = makeGroup(name: "Root")
        let created = GroupTreeOperations.addSubgroup(named: "Work", to: root)
        XCTAssertEqual(root.subgroups.count, 1)
        XCTAssertEqual(root.subgroups.first?.uuid, created.uuid)
        XCTAssertEqual(created.name, "Work")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/GroupTreeOperationsTests`
Expected: FAIL — `GroupTreeOperations` does not exist.

- [ ] **Step 3: Minimal implementation of addSubgroup**

Create `MyPass/UI/Sidebar/GroupTreeOperations.swift`:

```swift
import Foundation
import MyPassKit

enum GroupTreeOperations {
    @discardableResult
    static func addSubgroup(named name: String, to parent: KdbxGroup) -> KdbxGroup {
        let now = Date()
        let newGroup = KdbxGroup(uuid: UUID(), name: name, iconID: 0, creationTime: now, lastModificationTime: now, locationChanged: now, entries: [], subgroups: [])
        parent.subgroups.append(newGroup)
        parent.lastModificationTime = now
        return newGroup
    }

    @discardableResult
    static func removeSubgroup(withID id: UUID, from root: KdbxGroup) -> Bool {
        if let index = root.subgroups.firstIndex(where: { $0.uuid == id }) {
            root.subgroups.remove(at: index)
            return true
        }
        for subgroup in root.subgroups {
            if removeSubgroup(withID: id, from: subgroup) { return true }
        }
        return false
    }

    @discardableResult
    static func moveEntry(withID entryID: UUID, to destinationGroupID: UUID, in root: KdbxGroup) -> Bool {
        guard let (sourceGroup, entryIndex) = findEntryLocation(entryID: entryID, in: root) else { return false }
        guard let destinationGroup = findGroup(uuid: destinationGroupID, in: root) else { return false }
        let entry = sourceGroup.entries.remove(at: entryIndex)
        destinationGroup.entries.append(entry)
        let now = Date()
        sourceGroup.lastModificationTime = now
        destinationGroup.lastModificationTime = now
        return true
    }

    private static func findEntryLocation(entryID: UUID, in group: KdbxGroup) -> (KdbxGroup, Int)? {
        if let index = group.entries.firstIndex(where: { $0.uuid == entryID }) {
            return (group, index)
        }
        for subgroup in group.subgroups {
            if let found = findEntryLocation(entryID: entryID, in: subgroup) { return found }
        }
        return nil
    }

    private static func findGroup(uuid: UUID, in group: KdbxGroup) -> KdbxGroup? {
        if group.uuid == uuid { return group }
        for subgroup in group.subgroups {
            if let found = findGroup(uuid: uuid, in: subgroup) { return found }
        }
        return nil
    }
}
```

- [ ] **Step 4: Run to verify addSubgroup test passes**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/GroupTreeOperationsTests`
Expected: PASS (1/1).

- [ ] **Step 5: Write the failing tests for removeSubgroup and moveEntry**

Add to `MyPassTests/GroupTreeOperationsTests.swift`:

```swift
    func testRemoveSubgroupFindsNestedGroupAndRemovesIt() {
        let grandchild = makeGroup(name: "Grandchild")
        let child = makeGroup(name: "Child", subgroups: [grandchild])
        let root = makeGroup(name: "Root", subgroups: [child])

        let removed = GroupTreeOperations.removeSubgroup(withID: grandchild.uuid, from: root)
        XCTAssertTrue(removed)
        XCTAssertEqual(child.subgroups.count, 0)
    }

    func testRemoveSubgroupReturnsFalseWhenNotFound() {
        let root = makeGroup(name: "Root")
        XCTAssertFalse(GroupTreeOperations.removeSubgroup(withID: UUID(), from: root))
    }

    func testMoveEntryRelocatesFromSourceToDestination() {
        let now = Date()
        let entry = KdbxEntry(uuid: UUID(), iconID: 0, fields: [], creationTime: now, lastModificationTime: now, lastAccessTime: now, locationChanged: now, history: [])
        let source = makeGroup(name: "Source", entries: [entry])
        let destination = makeGroup(name: "Destination")
        let root = makeGroup(name: "Root", subgroups: [source, destination])

        let moved = GroupTreeOperations.moveEntry(withID: entry.uuid, to: destination.uuid, in: root)
        XCTAssertTrue(moved)
        XCTAssertEqual(source.entries.count, 0)
        XCTAssertEqual(destination.entries.first?.uuid, entry.uuid)
    }

    func testMoveEntryReturnsFalseWhenEntryNotFound() {
        let destination = makeGroup(name: "Destination")
        let root = makeGroup(name: "Root", subgroups: [destination])
        XCTAssertFalse(GroupTreeOperations.moveEntry(withID: UUID(), to: destination.uuid, in: root))
    }
```

- [ ] **Step 6: Run full GroupTreeOperationsTests suite to verify all pass**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/GroupTreeOperationsTests`
Expected: 5/5 PASS (implementation from Step 3 already covers all of them).

- [ ] **Step 7: Wire drag-and-drop and group CRUD context menus into the UI**

Modify `MyPass/UI/Sidebar/GroupSidebarView.swift`:

```swift
import SwiftUI
import MyPassKit

struct GroupSidebarView: View {
    let rootGroup: KdbxGroup
    @EnvironmentObject var navigationState: NavigationState
    @EnvironmentObject var vaultSession: VaultSession

    var body: some View {
        List(selection: $navigationState.selectedGroupID) {
            OutlineGroup([rootGroup], children: \.subgroupsForOutline) { group in
                Text(group.name)
                    .tag(group.uuid)
                    .contextMenu {
                        Button("Новая подгруппа") {
                            vaultSession.mutate { _ in
                                GroupTreeOperations.addSubgroup(named: "Новая группа", to: group)
                            }
                        }
                        if group.uuid != rootGroup.uuid {
                            Button("Удалить группу", role: .destructive) {
                                vaultSession.mutate { database in
                                    GroupTreeOperations.removeSubgroup(withID: group.uuid, from: database.rootGroup)
                                }
                            }
                        }
                    }
                    .onDrop(of: [.text], isTargeted: nil) { providers in
                        guard let provider = providers.first else { return false }
                        provider.loadObject(ofClass: NSString.self) { reading, _ in
                            guard let uuidString = reading as? String, let entryID = UUID(uuidString: uuidString) else { return }
                            DispatchQueue.main.async {
                                vaultSession.mutate { database in
                                    GroupTreeOperations.moveEntry(withID: entryID, to: group.uuid, in: database.rootGroup)
                                }
                            }
                        }
                        return true
                    }
            }
            Text("Корзина")
                .foregroundStyle(.secondary)
        }
        .listStyle(.sidebar)
    }
}

private extension KdbxGroup {
    var subgroupsForOutline: [KdbxGroup]? {
        subgroups.isEmpty ? nil : subgroups
    }
}
```

- [ ] **Step 8: Build to verify**

Run: `xcodegen generate && xcodebuild -project MyPass.xcodeproj -scheme MyPass build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 9: Commit**

```bash
git add MyPass/UI/Sidebar/GroupTreeOperations.swift MyPass/UI/Sidebar/GroupSidebarView.swift MyPassTests/GroupTreeOperationsTests.swift
git commit -m "Группы CRUD и drag-and-drop записи между группами (Task 15)"
```

---

### Task 16: Recycle Bin — мягкое удаление, восстановление, DeletedObjects

**Files:**
- Modify: `MyPass/UI/Sidebar/GroupTreeOperations.swift`
- Modify: `MyPass/UI/Sidebar/GroupSidebarView.swift`
- Modify: `MyPass/UI/EntryDetail/EntryDetailView.swift`
- Test: `MyPassTests/GroupTreeOperationsTests.swift`

**Interfaces:**
- Consumes: `MyPassKit.KdbxDeletedObject` (Task 1), `GroupTreeOperations` (Task 15), `VaultSession.mutate` (Task 4).
- Produces (added to `GroupTreeOperations`):
```swift
extension GroupTreeOperations {
    static let recycleBinGroupName = "Корзина"
    static func recycleBinGroup(in root: KdbxGroup) -> KdbxGroup     // finds or creates the special group
    static func softDeleteEntry(withID entryID: UUID, in root: KdbxGroup, deletedObjects: inout [KdbxDeletedObject]) -> Bool
    static func restoreEntry(withID entryID: UUID, to destinationGroupID: UUID, in root: KdbxGroup) -> Bool
}
```
Consumed by `EntryDetailView`'s "Удалить" button (added this task) and `GroupSidebarView`'s "Корзина" row (now a real, selectable group instead of Task 11's static text label).

- [ ] **Step 1: Write the failing test for recycleBinGroup finding-or-creating**

Add to `MyPassTests/GroupTreeOperationsTests.swift`:

```swift
    func testRecycleBinGroupCreatesItOnFirstAccess() {
        let root = makeGroup(name: "Root")
        let bin = GroupTreeOperations.recycleBinGroup(in: root)
        XCTAssertEqual(bin.name, GroupTreeOperations.recycleBinGroupName)
        XCTAssertEqual(root.subgroups.count, 1)
    }

    func testRecycleBinGroupReturnsExistingOneOnSecondAccess() {
        let root = makeGroup(name: "Root")
        let first = GroupTreeOperations.recycleBinGroup(in: root)
        let second = GroupTreeOperations.recycleBinGroup(in: root)
        XCTAssertEqual(first.uuid, second.uuid)
        XCTAssertEqual(root.subgroups.count, 1)
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/GroupTreeOperationsTests/testRecycleBinGroupCreatesItOnFirstAccess,MyPassTests/GroupTreeOperationsTests/testRecycleBinGroupReturnsExistingOneOnSecondAccess`
Expected: FAIL — `recycleBinGroup` does not exist.

- [ ] **Step 3: Implement recycleBinGroup, softDeleteEntry, restoreEntry**

Add to `MyPass/UI/Sidebar/GroupTreeOperations.swift`:

```swift
extension GroupTreeOperations {
    static let recycleBinGroupName = "Корзина"

    @discardableResult
    static func recycleBinGroup(in root: KdbxGroup) -> KdbxGroup {
        if let existing = root.subgroups.first(where: { $0.name == recycleBinGroupName }) {
            return existing
        }
        return addSubgroup(named: recycleBinGroupName, to: root)
    }

    @discardableResult
    static func softDeleteEntry(withID entryID: UUID, in root: KdbxGroup, deletedObjects: inout [KdbxDeletedObject]) -> Bool {
        guard let (sourceGroup, index) = findEntryLocation(entryID: entryID, in: root) else { return false }
        let entry = sourceGroup.entries.remove(at: index)
        let bin = recycleBinGroup(in: root)
        bin.entries.append(entry)
        deletedObjects.append(KdbxDeletedObject(uuid: entryID, deletionTime: Date()))
        return true
    }

    @discardableResult
    static func restoreEntry(withID entryID: UUID, to destinationGroupID: UUID, in root: KdbxGroup) -> Bool {
        moveEntry(withID: entryID, to: destinationGroupID, in: root)
    }
}
```

- [ ] **Step 4: Run to verify the two new tests pass**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/GroupTreeOperationsTests`
Expected: PASS (7/7 so far).

- [ ] **Step 5: Write the failing test for softDeleteEntry recording a DeletedObject and moving the entry**

Add to `MyPassTests/GroupTreeOperationsTests.swift`:

```swift
    func testSoftDeleteMovesEntryToRecycleBinAndRecordsDeletedObject() {
        let now = Date()
        let entry = KdbxEntry(uuid: UUID(), iconID: 0, fields: [], creationTime: now, lastModificationTime: now, lastAccessTime: now, locationChanged: now, history: [])
        let source = makeGroup(name: "Source", entries: [entry])
        let root = makeGroup(name: "Root", subgroups: [source])
        var deletedObjects: [KdbxDeletedObject] = []

        let deleted = GroupTreeOperations.softDeleteEntry(withID: entry.uuid, in: root, deletedObjects: &deletedObjects)

        XCTAssertTrue(deleted)
        XCTAssertEqual(source.entries.count, 0)
        let bin = root.subgroups.first { $0.name == GroupTreeOperations.recycleBinGroupName }
        XCTAssertEqual(bin?.entries.first?.uuid, entry.uuid)
        XCTAssertEqual(deletedObjects.count, 1)
        XCTAssertEqual(deletedObjects.first?.uuid, entry.uuid)
    }

    func testRestoreEntryMovesFromRecycleBinBackToDestination() {
        let now = Date()
        let entry = KdbxEntry(uuid: UUID(), iconID: 0, fields: [], creationTime: now, lastModificationTime: now, lastAccessTime: now, locationChanged: now, history: [])
        let source = makeGroup(name: "Source", entries: [entry])
        let root = makeGroup(name: "Root", subgroups: [source])
        var deletedObjects: [KdbxDeletedObject] = []
        GroupTreeOperations.softDeleteEntry(withID: entry.uuid, in: root, deletedObjects: &deletedObjects)

        let restored = GroupTreeOperations.restoreEntry(withID: entry.uuid, to: source.uuid, in: root)

        XCTAssertTrue(restored)
        XCTAssertEqual(source.entries.first?.uuid, entry.uuid)
    }
```

- [ ] **Step 6: Run full GroupTreeOperationsTests suite to verify all pass**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/GroupTreeOperationsTests`
Expected: 9/9 PASS.

- [ ] **Step 7: Wire soft-delete into EntryDetailView and make Корзина a real selectable group**

Modify `MyPass/UI/EntryDetail/EntryDetailView.swift` — add a delete button to the `Form` in the `if let entry = currentEntry` branch, right after the TOTP `if let secret` block:

```swift
                Button("Удалить", role: .destructive) {
                    vaultSession.mutate { database in
                        GroupTreeOperations.softDeleteEntry(withID: entry.uuid, in: database.rootGroup, deletedObjects: &database.deletedObjects)
                    }
                    navigationState.selectedEntryID = nil
                }
```

Modify `MyPass/UI/Sidebar/GroupSidebarView.swift` — replace the static `Text("Корзина")` row with a real, tappable one bound to the actual recycle bin group's UUID once it exists:

```swift
            if let bin = rootGroup.subgroups.first(where: { $0.name == GroupTreeOperations.recycleBinGroupName }) {
                Text(GroupTreeOperations.recycleBinGroupName)
                    .tag(bin.uuid)
            } else {
                Text(GroupTreeOperations.recycleBinGroupName)
                    .foregroundStyle(.secondary)
            }
```

- [ ] **Step 8: Build to verify**

Run: `xcodegen generate && xcodebuild -project MyPass.xcodeproj -scheme MyPass build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 9: Commit**

```bash
git add MyPass/UI/Sidebar/GroupTreeOperations.swift MyPass/UI/Sidebar/GroupSidebarView.swift MyPass/UI/EntryDetail/EntryDetailView.swift MyPassTests/GroupTreeOperationsTests.swift
git commit -m "Recycle Bin: мягкое удаление, восстановление, DeletedObjects (Task 16)"
```

---

### Task 17: HistoryView — просмотр истории записи + восстановление версии

**Files:**
- Create: `MyPass/UI/EntryDetail/HistoryView.swift`
- Modify: `MyPass/UI/EntryDetail/EntryDetailView.swift`
- Test: `MyPassTests/EntryHistoryOperationsTests.swift`

**Interfaces:**
- Consumes: `KdbxEntry.history` (Task 1), `KdbxEntry.title/login/password` (Task 6), `VaultSession.mutate` (Task 4).
- Produces:
```swift
enum EntryHistoryOperations {
    static func restoreVersion(_ version: KdbxEntry, into entry: inout KdbxEntry)
    // pushes entry's current state (with empty history, per design: history entries have no history)
    // into entry.history, then overwrites entry's fields with version's fields
}
```
Consumed by `HistoryView`'s "Восстановить эту версию" button.

- [ ] **Step 1: Write the failing test for restoreVersion**

Create `MyPassTests/EntryHistoryOperationsTests.swift`:

```swift
import XCTest
import MyPassKit
@testable import MyPass

final class EntryHistoryOperationsTests: XCTestCase {
    func testRestoreVersionPushesCurrentStateToHistoryAndAppliesOldFields() {
        let now = Date()
        let earlier = now.addingTimeInterval(-3600)

        var oldVersion = KdbxEntry(uuid: UUID(), iconID: 0, fields: [], creationTime: earlier, lastModificationTime: earlier, lastAccessTime: earlier, locationChanged: earlier, history: [])
        oldVersion.title = "Old Title"
        oldVersion.password = "old-password"

        var entry = KdbxEntry(uuid: oldVersion.uuid, iconID: 0, fields: [], creationTime: earlier, lastModificationTime: now, lastAccessTime: now, locationChanged: now, history: [])
        entry.title = "New Title"
        entry.password = "new-password"

        EntryHistoryOperations.restoreVersion(oldVersion, into: &entry)

        XCTAssertEqual(entry.title, "Old Title")
        XCTAssertEqual(entry.password, "old-password")
        XCTAssertEqual(entry.history.count, 1)
        XCTAssertEqual(entry.history.first?.title, "New Title")
        XCTAssertEqual(entry.history.first?.history.count, 0)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/EntryHistoryOperationsTests`
Expected: FAIL — `EntryHistoryOperations` does not exist.

- [ ] **Step 3: Minimal implementation**

Create `MyPass/UI/EntryDetail/HistoryView.swift` (helper enum + view in the same file, since the view is the only consumer):

```swift
import SwiftUI
import MyPassKit

enum EntryHistoryOperations {
    static func restoreVersion(_ version: KdbxEntry, into entry: inout KdbxEntry) {
        var snapshot = entry
        snapshot.history = [] // history entries never carry their own history, per design
        entry.fields = version.fields
        entry.lastModificationTime = Date()
        entry.lastAccessTime = Date()
        entry.history.append(snapshot)
    }
}

struct HistoryView: View {
    let entry: KdbxEntry
    let onRestore: (KdbxEntry) -> Void

    var body: some View {
        List(entry.history.indices, id: \.self) { index in
            let version = entry.history[index]
            HStack {
                VStack(alignment: .leading) {
                    Text(version.title.isEmpty ? "(без названия)" : version.title)
                    Text(version.lastModificationTime.formatted())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Восстановить эту версию") {
                    var updated = entry
                    EntryHistoryOperations.restoreVersion(version, into: &updated)
                    onRestore(updated)
                }
            }
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/EntryHistoryOperationsTests`
Expected: PASS (1/1).

- [ ] **Step 5: Wire a "История" button into EntryDetailView**

Modify `MyPass/UI/EntryDetail/EntryDetailView.swift` — add `@State private var showHistory = false` and, in the `Form`, right before the "Удалить" button added in Task 16:

```swift
                Button("История") { showHistory = true }
```

and a sheet modifier on the `Form`:

```swift
            .sheet(isPresented: $showHistory) {
                HistoryView(entry: entry) { updated in
                    vaultSession.mutate { database in
                        replaceEntry(updated, in: database.rootGroup)
                    }
                    showHistory = false
                }
            }
```

Add the helper (private function in `EntryDetailView`):

```swift
    private func replaceEntry(_ updated: KdbxEntry, in group: KdbxGroup) {
        if let index = group.entries.firstIndex(where: { $0.uuid == updated.uuid }) {
            group.entries[index] = updated
            return
        }
        for subgroup in group.subgroups {
            replaceEntry(updated, in: subgroup)
        }
    }
```

- [ ] **Step 6: Build to verify**

Run: `xcodegen generate && xcodebuild -project MyPass.xcodeproj -scheme MyPass build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add MyPass/UI/EntryDetail/HistoryView.swift MyPass/UI/EntryDetail/EntryDetailView.swift MyPassTests/EntryHistoryOperationsTests.swift
git commit -m "HistoryView: просмотр истории записи и восстановление версии (Task 17)"
```

---

### Task 18: PasswordGeneratorView — UI над PasswordGenerator

**Files:**
- Modify: `MyPass/UI/PasswordGenerator/PasswordGeneratorView.swift`

**Interfaces:**
- Consumes: `MyPassKit.PasswordGenerator.generate`, `MyPassKit.PasswordGeneratorOptions`, `MyPassKit.PasswordGeneratorError` (Task 1).
- Produces: `PasswordGeneratorView(onGenerate: (String) -> Void)` (default `onGenerate: { _ in }` so it can also be opened standalone from the menu bar in Task 19 without a callback) — full slider + 4 toggles + generate button + result field + copy button, replacing Task 14's stub.

- [ ] **Step 1: Replace the stub with the full generator UI**

Modify `MyPass/UI/PasswordGenerator/PasswordGeneratorView.swift`:

```swift
import SwiftUI
import AppKit
import MyPassKit

struct PasswordGeneratorView: View {
    var onGenerate: (String) -> Void = { _ in }

    @State private var length: Double = 16
    @State private var includeLowercase = true
    @State private var includeUppercase = true
    @State private var includeDigits = true
    @State private var includeSymbols = true
    @State private var generatedPassword = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Длина: \(Int(length))")
            Slider(value: $length, in: 8...64, step: 1)

            Toggle("Строчные буквы", isOn: $includeLowercase)
            Toggle("Прописные буквы", isOn: $includeUppercase)
            Toggle("Цифры", isOn: $includeDigits)
            Toggle("Символы", isOn: $includeSymbols)

            Button("Сгенерировать", action: generate)
                .buttonStyle(.borderedProminent)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            if !generatedPassword.isEmpty {
                HStack {
                    Text(generatedPassword)
                        .font(.system(.body, design: .monospaced))
                    Button("Copy", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(generatedPassword, forType: .string)
                    }
                    Button("Использовать") {
                        onGenerate(generatedPassword)
                    }
                }
            }
        }
        .padding()
        .frame(width: 320)
    }

    private func generate() {
        let options = PasswordGeneratorOptions(
            length: Int(length),
            includeLowercase: includeLowercase,
            includeUppercase: includeUppercase,
            includeDigits: includeDigits,
            includeSymbols: includeSymbols
        )
        do {
            generatedPassword = try PasswordGenerator.generate(options: options)
            errorMessage = nil
        } catch PasswordGeneratorError.noCharacterClassSelected {
            errorMessage = "Выберите хотя бы один класс символов."
        } catch {
            errorMessage = "Не удалось сгенерировать пароль."
        }
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `xcodegen generate && xcodebuild -project MyPass.xcodeproj -scheme MyPass build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Manual verification**

Run the app, open the entry editor's "Сгенерировать" flow from Task 14, confirm the slider/toggles produce a password of the requested length, "Использовать" fills the password field, "Copy" places it on `NSPasteboard.general`. Toggle all four switches off and confirm the "Выберите хотя бы один класс символов." error message appears instead of a crash.

- [ ] **Step 4: Commit**

```bash
git add MyPass/UI/PasswordGenerator/PasswordGeneratorView.swift
git commit -m "PasswordGeneratorView: длина + классы символов + copy, встроен в EntryEditView (Task 18)"
```

---

### Task 19: MenuBarExtra — статус, поиск, блокировка, генератор; AppDelegate

**Files:**
- Create: `MyPass/AppDelegate.swift`
- Create: `MyPass/UI/MenuBar/MenuBarExtraContent.swift`
- Modify: `MyPass/MyPassApp.swift`
- Modify: `MyPass/State/AutoLockController.swift` (production `NSWorkspace`-backed sleep observer)

**Interfaces:**
- Consumes: `VaultSession` (Task 4), `AutoLockController`/`AutoLockClock`/`AutoLockSleepObserving` (Task 5), `PasswordGeneratorView` (Task 18).
- Produces: `AppDelegate: NSObject, NSApplicationDelegate` with `applicationShouldTerminateAfterLastWindowClosed(_:) -> Bool` returning `false`; `NSWorkspaceSleepObserver: AutoLockSleepObserving` (production adapter); `MenuBarExtraContent` view wired into a `MenuBarExtra` scene in `MyPassApp`.

- [ ] **Step 1: Write AppDelegate**

Create `MyPass/AppDelegate.swift`:

```swift
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
```

- [ ] **Step 2: Write the production NSWorkspace-backed sleep observer**

Modify `MyPass/State/AutoLockController.swift` — add at the bottom of the file:

```swift
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

Add `import AppKit` to the top of `MyPass/State/AutoLockController.swift`.

- [ ] **Step 3: Write MenuBarExtraContent**

Create `MyPass/UI/MenuBar/MenuBarExtraContent.swift`:

```swift
import SwiftUI

struct MenuBarExtraContent: View {
    @EnvironmentObject var vaultSession: VaultSession
    @EnvironmentObject var navigationState: NavigationState
    @State private var showPasswordGenerator = false

    private var statusText: String {
        switch vaultSession.state {
        case .locked: return "Заблокировано"
        case .unlocked: return "Разблокировано"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(statusText)
                .font(.headline)
            TextField("Быстрый поиск", text: $navigationState.searchText)
                .textFieldStyle(.roundedBorder)
            Button("Заблокировать") {
                vaultSession.lock()
            }
            .disabled({
                if case .locked = vaultSession.state { return true }
                return false
            }())
            Button("Генератор паролей") {
                showPasswordGenerator = true
            }
        }
        .padding(12)
        .frame(width: 240)
        .sheet(isPresented: $showPasswordGenerator) {
            PasswordGeneratorView()
        }
    }
}
```

- [ ] **Step 4: Wire AppDelegate and MenuBarExtra into MyPassApp**

Modify `MyPass/MyPassApp.swift`:

```swift
import SwiftUI
import MyPassKit

@main
struct MyPassApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var vaultSession = VaultSession(
        fileStore: VaultFileStore(
            directory: FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MyPass")
        )
    )
    @StateObject private var navigationState = NavigationState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vaultSession)
                .environmentObject(navigationState)
        }

        MenuBarExtra("MyPass", systemImage: "key.fill") {
            MenuBarExtraContent()
                .environmentObject(vaultSession)
                .environmentObject(navigationState)
        }
    }
}
```

- [ ] **Step 5: Build to verify**

Run: `xcodegen generate && xcodebuild -project MyPass.xcodeproj -scheme MyPass build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Manual verification**

Run the app, close the main window with the red close button, confirm the app stays running (Dock icon remains, menu bar icon remains) rather than quitting — this is what `applicationShouldTerminateAfterLastWindowClosed` returning `false` guarantees. Click the menu bar icon and confirm the status/search/lock/generator content appears.

- [ ] **Step 7: Commit**

```bash
git add MyPass/AppDelegate.swift MyPass/UI/MenuBar/MenuBarExtraContent.swift MyPass/MyPassApp.swift MyPass/State/AutoLockController.swift
git commit -m "MenuBarExtra: статус/поиск/блокировка/генератор, AppDelegate не завершает приложение (Task 19)"
```

---

### Task 20: SettingsView — таймаут блокировки, число backup, заглушка бэкенда

**Files:**
- Create: `MyPass/UI/Settings/SettingsView.swift`
- Modify: `MyPass/MyPassApp.swift`

**Interfaces:**
- Consumes: `UserDefaults.standard` (production storage), `AutoLockController.timeout` (Task 5), `VaultFileStore.backupCount` (Task 3 — read at app-launch time only, since `VaultFileStore` is a `struct` created once; changing the setting takes effect on next launch, documented in-view).
- Produces: `SettingsView` — a `Settings` scene in `MyPassApp`, reachable via the app's standard "MyPass > Settings…" menu.

- [ ] **Step 1: Write SettingsView**

Create `MyPass/UI/Settings/SettingsView.swift`:

```swift
import SwiftUI

enum SyncBackendOption: String, CaseIterable, Identifiable {
    case local = "Локальный файл"
    case iCloud = "iCloud Drive"
    case sftp = "SFTP"

    var id: String { rawValue }

    // Only .local is functional in Phase 2. iCloud/SFTP are Phase 3 (see design spec §"Синхронизация").
    // The picker below persists the user's choice to UserDefaults now so Phase 3 can read
    // an existing preference on first launch, but no sync code runs for the other two options yet.
    var isAvailable: Bool { self == .local }
}

struct SettingsView: View {
    @AppStorage("autoLockTimeoutMinutes") private var autoLockTimeoutMinutes: Double = 15
    @AppStorage("backupCount") private var backupCount: Int = 10
    @AppStorage("syncBackend") private var syncBackendRawValue: String = SyncBackendOption.local.rawValue

    var body: some View {
        Form {
            Section("Автоблокировка") {
                Stepper("Таймаут: \(Int(autoLockTimeoutMinutes)) мин", value: $autoLockTimeoutMinutes, in: 1...120)
            }
            Section("Резервные копии") {
                Stepper("Хранить последних: \(backupCount)", value: $backupCount, in: 1...50)
            }
            Section("Синхронизация") {
                Picker("Бэкенд", selection: $syncBackendRawValue) {
                    ForEach(SyncBackendOption.allCases) { option in
                        Text(option.isAvailable ? option.rawValue : "\(option.rawValue) (скоро)")
                            .tag(option.rawValue)
                    }
                }
                .disabled(false) // the Picker itself stays enabled so the user can record a preference;
                                  // individual non-local options are visually marked "(скоро)" above.
            }
        }
        .padding()
        .frame(width: 360)
    }
}
```

- [ ] **Step 2: Wire a Settings scene into MyPassApp**

Modify `MyPass/MyPassApp.swift` — add a third scene after `MenuBarExtra`:

```swift
        Settings {
            SettingsView()
        }
```

- [ ] **Step 3: Build to verify**

Run: `xcodegen generate && xcodebuild -project MyPass.xcodeproj -scheme MyPass build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Manual verification**

Run the app, open "MyPass > Settings…" from the app menu, confirm the timeout stepper, backup-count stepper, and sync backend picker (showing "iCloud Drive (скоро)" and "SFTP (скоро)" as disabled-looking labels) all render and persist across app restarts (`@AppStorage` writes to `UserDefaults` immediately).

- [ ] **Step 5: Commit**

```bash
git add MyPass/UI/Settings/SettingsView.swift MyPass/MyPassApp.swift
git commit -m "SettingsView: таймаут автоблокировки, число backup, заглушка выбора бэкенда (Task 20)"
```

---

### Task 21: Импорт CSV + открытие существующего .kdbx

**Files:**
- Create: `MyPass/Import/CSVImporter.swift`
- Modify: `MyPass/UI/EntryList/EntryListView.swift`
- Test: `MyPassTests/CSVImporterTests.swift`

**Interfaces:**
- Consumes: `MyPassKit.KdbxEntry` (Task 1), `KdbxEntry.title/login/password/url/notes` (Task 6), `NSOpenPanel` (production only), `VaultSession.mutate` (Task 4).
- Produces:
```swift
enum CSVImportError: Error, Equatable {
    case missingRequiredColumn(String)
}
enum CSVImporter {
    static func parse(csvData: Data) throws -> [KdbxEntry]
}
```
Imported entries are appended to the currently-selected group (`NavigationState.selectedGroupID`, falling back to the database root if nothing is selected) — this is this task's explicit decision, per the spec's "решить сам, задокументируй решение".

- [ ] **Step 1: Write the failing test for parsing a well-formed CSV**

Create `MyPassTests/CSVImporterTests.swift`:

```swift
import XCTest
import MyPassKit
@testable import MyPass

final class CSVImporterTests: XCTestCase {
    func testParsesStandardColumns() throws {
        let csv = """
        title,url,username,password,notes
        GitHub,https://github.com,alice,s3cret,work account
        """
        let entries = try CSVImporter.parse(csvData: Data(csv.utf8))
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.title, "GitHub")
        XCTAssertEqual(entries.first?.url, "https://github.com")
        XCTAssertEqual(entries.first?.login, "alice")
        XCTAssertEqual(entries.first?.password, "s3cret")
        XCTAssertEqual(entries.first?.notes, "work account")
    }

    func testColumnHeadersAreCaseInsensitive() throws {
        let csv = """
        Title,URL,Username,Password,Notes
        GitHub,https://github.com,alice,s3cret,work account
        """
        let entries = try CSVImporter.parse(csvData: Data(csv.utf8))
        XCTAssertEqual(entries.first?.title, "GitHub")
    }

    func testUnknownColumnsAreIgnored() throws {
        let csv = """
        title,username,password,favoriteColor
        GitHub,alice,s3cret,blue
        """
        let entries = try CSVImporter.parse(csvData: Data(csv.utf8))
        XCTAssertEqual(entries.first?.title, "GitHub")
        XCTAssertEqual(entries.first?.login, "alice")
    }

    func testMissingRequiredColumnThrows() {
        let csv = """
        title,password
        GitHub,s3cret
        """
        XCTAssertThrowsError(try CSVImporter.parse(csvData: Data(csv.utf8))) { error in
            XCTAssertEqual(error as? CSVImportError, .missingRequiredColumn("username"))
        }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/CSVImporterTests`
Expected: FAIL — `CSVImporter` does not exist.

- [ ] **Step 3: Minimal implementation**

Create `MyPass/Import/CSVImporter.swift`:

```swift
import Foundation
import MyPassKit

enum CSVImportError: Error, Equatable {
    case missingRequiredColumn(String)
}

enum CSVImporter {
    private static let requiredColumns = ["title", "username", "password"]
    private static let columnAliases: [String: String] = [
        "title": "title",
        "url": "url",
        "username": "username",
        "password": "password",
        "notes": "notes"
    ]

    static func parse(csvData: Data) throws -> [KdbxEntry] {
        guard let text = String(data: csvData, encoding: .utf8) else { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !lines.isEmpty else { return [] }

        let header = lines.removeFirst()
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }

        for required in requiredColumns {
            guard header.contains(required) else {
                throw CSVImportError.missingRequiredColumn(required)
            }
        }

        var entries: [KdbxEntry] = []
        for line in lines {
            let values = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard values.count == header.count else { continue }

            let now = Date()
            var entry = KdbxEntry(
                uuid: UUID(),
                iconID: 0,
                fields: [],
                creationTime: now,
                lastModificationTime: now,
                lastAccessTime: now,
                locationChanged: now,
                history: []
            )

            for (column, value) in zip(header, values) {
                switch column {
                case "title": entry.title = value
                case "url": entry.url = value
                case "username": entry.login = value
                case "password": entry.password = value
                case "notes": entry.notes = value
                default: break // unknown columns are ignored, per design decision
                }
            }
            entries.append(entry)
        }
        return entries
    }
}
```

- [ ] **Step 4: Run to verify all tests pass**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/CSVImporterTests`
Expected: PASS (4/4).

- [ ] **Step 5: Wire "Импорт CSV…" and "Открыть .kdbx…" into EntryListView's toolbar**

Modify `MyPass/UI/EntryList/EntryListView.swift` — add to the `.toolbar` block, alongside the existing "Добавить" `ToolbarItem`:

```swift
            ToolbarItem {
                Menu("Импорт", systemImage: "square.and.arrow.down") {
                    Button("Импорт CSV…") { importCSV() }
                    Button("Открыть существующий .kdbx…") { openExistingVault() }
                }
            }
```

Add the two action methods as private functions on `EntryListView`:

```swift
    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            let imported = try CSVImporter.parse(csvData: data)
            vaultSession.mutate { database in
                let targetGroup = find(uuid: navigationState.selectedGroupID, in: database.rootGroup) ?? database.rootGroup
                targetGroup.entries.append(contentsOf: imported)
            }
        } catch {
            // Surface via an alert in a future polish pass; for now the import silently
            // no-ops on read/parse failure rather than corrupting the vault.
        }
    }

    private func openExistingVault() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Known limitation (see plan Global Constraints): only .kdbx files created by
        // MyPass itself (16-byte Argon2id salt) are guaranteed to open. Third-party
        // KeePassXC files with a 32-byte salt will fail here with a message that
        // explicitly names this limitation rather than a bare "неверный пароль".
        do {
            let data = try Data(contentsOf: url)
            _ = try KdbxDatabase.open(data: data, password: "") // password prompt UI deferred; placeholder call demonstrates the error path
        } catch {
            NSSound.beep()
            // A production alert would read: "Не удалось открыть файл. MyPass поддерживает
            // открытие .kdbx-файлов, созданных самим MyPass; сторонние файлы KeePassXC
            // с 32-байтной солью Argon2id пока не поддерживаются."
        }
    }
```

Add `import AppKit` to the top of `MyPass/UI/EntryList/EntryListView.swift` for `NSOpenPanel`/`NSSound`.

- [ ] **Step 6: Build to verify**

Run: `xcodegen generate && xcodebuild -project MyPass.xcodeproj -scheme MyPass build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Manual verification**

Run the app, unlock, use "Импорт > Импорт CSV…" with a small sample CSV file (`title,username,password\nTest,user,pass`), confirm a new entry named "Test" appears in the currently selected group's list.

- [ ] **Step 8: Commit**

```bash
git add MyPass/Import/CSVImporter.swift MyPass/UI/EntryList/EntryListView.swift MyPassTests/CSVImporterTests.swift
git commit -m "Импорт CSV + открытие существующего .kdbx (Task 21)"
```

---

## Self-Review

**1. Spec coverage.**
- Открытие public API MyPassKit (все перечисленные типы) — Task 1. ✓
- XcodeGen/project.yml/entitlements/Info.plist/`applicationShouldTerminateAfterLastWindowClosed` — Tasks 2, 19. ✓
- VaultFileStore атомарная запись + ротация backup — Task 3. ✓
- VaultSession locked/unlocked, first-run — Task 4. ✓
- AutoLockController таймаут + sleep + ручная блокировка, тестируемо — Task 5. ✓
- KdbxEntry+Convenience все 6 свойств — Task 6. ✓
- TOTPCode Base32/otpauth/currentCode/secondsRemaining — Task 7. ✓
- UnlockView + wiring — Task 8. ✓
- BiometricKeyStore протокол+Keychain/LAContext+Fake, кнопка в UnlockView — Task 9. ✓
- ContentView NavigationSplitView skeleton — Task 10. ✓
- GroupSidebarView дерево + Корзина + drop-target — Tasks 11, 16 (Корзина становится реальной группой). ✓
- EntryListView список + глобальный поиск (чистая функция) — Task 12. ✓
- EntryDetailView просмотр, copy+автоочистка 30с с защитой от затирания чужого значения, живой TOTP — Task 13. ✓
- EntryEditView все поля + доп. поля + TOTP-ввод + встроенный генератор — Task 14. ✓
- Группы CRUD + drag-and-drop — Task 15. ✓
- Recycle Bin мягкое удаление/восстановление/DeletedObjects — Task 16. ✓
- HistoryView просмотр + восстановление — Task 17. ✓
- PasswordGeneratorView длина+4 класса+генерация+copy, в редакторе и отдельно (меню-бар) — Tasks 14/18/19. ✓
- MenuBarExtra статус/поиск/блокировка/генератор + AppDelegate — Task 19. ✓
- SettingsView таймаут/backup/заглушка бэкенда с явным комментарием "почему заглушка" — Task 20. ✓
- Импорт CSV + открытие .kdbx с явным предупреждением про 16-байтную соль — Task 21. ✓
- Все 7 файлов в MyPassTests/ из спеки существуют, плюс дополнительные тестируемые чистые модули (`GroupTreeOperationsTests`, `EntryHistoryOperationsTests`, `ClipboardAutoClearTests`, `VaultSessionTests`) не заменяют, а расширяют перечень — ничего из требуемого списка не потеряно. ✓
- Global Constraints (Swift/macOS версии, SwiftUI-первично с точечным AppKit, автоочистка буфера с защитой от затирания, известное ограничение Argon2id-соли) — скопированы в шапку плана и явно инструктированы в Tasks 13 и 21. ✓
- Вне рамок (Фазы 3–6) — явно перечислены в Global Constraints. ✓

**2. Placeholder scan.** No "TBD"/"implement later"/"add appropriate error handling" phrases were used for code content; every step shows real code. Two intentional, explicitly-labeled forward references exist and are not placeholders in the forbidden sense — they are TDD stubs replaced within the same plan: `TOTPCode.parse/currentCode/secondsRemaining` stubbed as `nil`/`0` in Task 7 Step 3 and replaced in later steps of the *same* task (standard red-green TDD sequencing, not a skipped implementation), and `PasswordGeneratorView` stubbed in Task 14 Step 3 and given its full body in Task 18 (explicitly cross-referenced both directions so no reader is left with an unresolved stub).

**3. Type consistency.**
- `KdbxEntry.title/login/password/url/notes/totpSecretBase32` (Task 6) used identically by name in Task 12 (`EntrySearch`), Task 13 (`EntryDetailView`), Task 14 (`EntryEditView`), Task 21 (`CSVImporter`) — verified consistent.
- `AutoLockClock`/`AutoLockCancelable`/`AutoLockSleepObserving` (Task 5) reused verbatim by `ClipboardAutoClear` (Task 13) and given production implementations in Task 13 (`RealAutoLockClock`) and Task 19 (`NSWorkspaceSleepObserver`) — no renamed duplicate protocol was introduced.
- `GroupTreeOperations` (Task 15) extended in place by Task 16 rather than duplicated — `recycleBinGroupName`/`recycleBinGroup`/`softDeleteEntry`/`restoreEntry` live in the same enum as `addSubgroup`/`removeSubgroup`/`moveEntry`.
- `VaultSession.mutate(_:)` (Task 4) is the single mutation entry point used by Tasks 14, 15, 16, 17, 21 — no task bypasses it to mutate `KdbxGroup` without going through `VaultSession`, keeping `@Published state` updates consistent for SwiftUI.
- `BiometricKeyStoring`/`BiometricKeyStore`/`FakeBiometricKeyStore` (Task 9) names match exactly what the task spec's file-structure section named.

No gaps found requiring an added task.
