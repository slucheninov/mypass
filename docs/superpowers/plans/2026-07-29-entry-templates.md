# Entry Templates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Card and Notes entry templates (alongside the existing Login template) to MyPass, each with its own create/edit/detail UI and its own sidebar smart-category filter, with zero migration needed for existing vaults.

**Architecture:** A new `MyPass.EntryType` custom KDBX string field (absent = Login) discriminates entry type. Card and Notes get their own `CardEditView`/`CardDetailView` and `NotesEditView`/`NotesDetailView` SwiftUI files (Approach B from the design spec — separate views per template, sharing a small set of extracted chrome components), wired in through a widened `NavigationState.presentCreate` and `ContentView`'s routing helper. Smart categories (`SmartCategory`, `EntryCategoryFilter`, sidebar, list row icons) get two new cases, following the exact pattern already used for `.favorites`/`.codes`.

**Tech Stack:** Swift 5 / SwiftUI, macOS 14+ (`MACOSX_DEPLOYMENT_TARGET = 14.0` in `MyPass.xcodeproj`, `platforms: [.macOS(.v14), .iOS(.v17)]` in `Packages/MyPassKit/Package.swift`), XCTest for unit tests, no new third-party dependencies (per spec non-goal: no markdown library — use `AttributedString(markdown:)`).

## Global Constraints

- English everywhere: code, comments, UI strings, commit messages (per repo `CLAUDE.md`).
- No new dependencies (SwiftPM packages) may be added — per spec non-goal "No new markdown dependency."
- No CSV import changes — Card/Notes stay out of `CSVImporter`.
- No changes to `ExtensionBridgeKit` (Chrome extension bridge) — Card/Notes are not exposed to it.
- No "convert entry type" action — editing an entry always opens the view matching its *existing* `entryType`; there is no UI to change an entry's type after creation.
- No card-brand detection or Luhn validation — card number formatting is display-grouping only.
- Every entry in every existing vault has no `MyPass.EntryType` field and must be treated as `.login` — this is a hard backward-compatibility requirement, not just a default value convenience.
- Follow existing codebase conventions exactly where a pattern already exists (masked/reveal field pattern, toolbar Cancel/Save pattern, copy-to-clipboard contextMenu pattern) rather than inventing new ones.

---

### Task 1: Data model — entry type discriminator

**Files:**
- Create: `MyPass/Models/EntryType.swift`
- Modify: `MyPass/Models/KdbxEntry+Convenience.swift`
- Test: `MyPassTests/KdbxEntryConvenienceTests.swift`
- Test: `Packages/MyPassKit/Tests/MyPassKitTests/KdbxXmlCoderTests.swift`

**Interfaces:**
- Consumes: `KdbxEntry` (`Packages/MyPassKit/Sources/MyPassKit/Model/KdbxEntry.swift`) — `fields: [KdbxField]`, plus the private `fieldValue(forKey:)` / `setFieldValue(_:forKey:isProtected:)` helpers already defined in `KdbxEntry+Convenience.swift`.
- Produces (used by all later tasks):
  - `enum EntryType: String { case login = "Login", card = "Card", notes = "Notes" }`
  - `KdbxEntry.entryType: EntryType` (get/set)
  - `KdbxEntry.cardNumber: String`, `.cardholderName: String`, `.expiryDate: String`, `.cvv: String`, `.notesBody: String` (get/set)
  - Updated `KdbxEntry.standardFieldKeys: Set<String>` including the 6 new keys.

- [ ] **Step 1: Write the failing tests in `MyPassTests/KdbxEntryConvenienceTests.swift`**

Add these test methods just before the final closing `}` of `KdbxEntryConvenienceTests` (after `testFavoriteFieldExcludedFromAdditionalFields`):

```swift
    func testEntryTypeDefaultsToLoginWhenFieldAbsent() {
        let entry = makeEmptyEntry()
        XCTAssertEqual(entry.entryType, .login)
    }

    func testEntryTypeRoundTripsForCardAndNotes() {
        var entry = makeEmptyEntry()
        entry.entryType = .card
        XCTAssertEqual(entry.entryType, .card)
        XCTAssertEqual(entry.fields.first(where: { $0.key == "MyPass.EntryType" })?.value, "Card")

        entry.entryType = .notes
        XCTAssertEqual(entry.entryType, .notes)
        XCTAssertEqual(entry.fields.first(where: { $0.key == "MyPass.EntryType" })?.value, "Notes")
    }

    func testEntryTypeSetterToLoginRemovesField() {
        var entry = makeEmptyEntry()
        entry.entryType = .card
        entry.entryType = .login
        XCTAssertEqual(entry.entryType, .login)
        XCTAssertNil(entry.fields.first(where: { $0.key == "MyPass.EntryType" }))
    }

    func testEntryTypeFieldExcludedFromAdditionalFields() {
        var entry = makeEmptyEntry()
        entry.entryType = .card
        entry.fields.append(KdbxField(key: "Custom Field", value: "custom value", isProtected: false))

        let keys = Set(entry.additionalFields.map(\.key))
        XCTAssertEqual(keys, ["Custom Field"])
        XCTAssertFalse(keys.contains("MyPass.EntryType"))
    }

    func testCardFieldsRoundTripAndAreProtectedWhereExpected() {
        var entry = makeEmptyEntry()
        entry.cardNumber = "4111111111111111"
        entry.cardholderName = "Jane Doe"
        entry.expiryDate = "09/28"
        entry.cvv = "123"

        XCTAssertEqual(entry.cardNumber, "4111111111111111")
        XCTAssertEqual(entry.cardholderName, "Jane Doe")
        XCTAssertEqual(entry.expiryDate, "09/28")
        XCTAssertEqual(entry.cvv, "123")
        XCTAssertEqual(entry.fields.first(where: { $0.key == "CardNumber" })?.isProtected, true)
        XCTAssertEqual(entry.fields.first(where: { $0.key == "CVV" })?.isProtected, true)
        XCTAssertEqual(entry.fields.first(where: { $0.key == "CardholderName" })?.isProtected, false)
        XCTAssertEqual(entry.fields.first(where: { $0.key == "ExpiryDate" })?.isProtected, false)
    }

    func testNotesBodyRoundTrips() {
        var entry = makeEmptyEntry()
        entry.notesBody = "# Heading\n\nSome **bold** text."
        XCTAssertEqual(entry.notesBody, "# Heading\n\nSome **bold** text.")
        XCTAssertEqual(entry.fields.first(where: { $0.key == "NotesBody" })?.isProtected, false)
    }

    func testTemplateFieldKeysExcludedFromAdditionalFields() {
        var entry = makeEmptyEntry()
        entry.cardNumber = "4111111111111111"
        entry.cardholderName = "Jane Doe"
        entry.expiryDate = "09/28"
        entry.cvv = "123"
        entry.notesBody = "note body"
        entry.fields.append(KdbxField(key: "Custom Field", value: "custom value", isProtected: false))

        let keys = Set(entry.additionalFields.map(\.key))
        XCTAssertEqual(keys, ["Custom Field"])
    }
```

- [ ] **Step 2: Run tests to verify they fail to compile**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/KdbxEntryConvenienceTests 2>&1 | tail -50`
Expected: build FAILS — `value of type 'KdbxEntry' has no member 'entryType'` (and `cardNumber`/`cardholderName`/`expiryDate`/`cvv`/`notesBody`).

- [ ] **Step 3: Create `MyPass/Models/EntryType.swift`**

```swift
import Foundation

/// Discriminates which template an entry was created from. Backed by the
/// `MyPass.EntryType` custom field (see `KdbxEntry.entryType`) — an absent
/// field means `.login`, so every entry in every pre-existing vault is
/// automatically and correctly treated as Login with no migration step.
enum EntryType: String {
    case login = "Login"
    case card = "Card"
    case notes = "Notes"
}
```

- [ ] **Step 4: Add the computed properties and update `standardFieldKeys` in `MyPass/Models/KdbxEntry+Convenience.swift`**

Inside the `extension KdbxEntry { ... }` block (the one currently containing `title`/`login`/`password`/`url`/`notes`/`totpSecretBase32`/`isFavorite`), add these properties right after `isFavorite` and before the extension's closing `}`:

```swift
    var entryType: EntryType {
        get { EntryType(rawValue: fieldValue(forKey: "MyPass.EntryType")) ?? .login }
        set {
            if newValue == .login {
                fields.removeAll { $0.key == "MyPass.EntryType" }
            } else {
                setFieldValue(newValue.rawValue, forKey: "MyPass.EntryType", isProtected: false)
            }
        }
    }

    var cardNumber: String {
        get { fieldValue(forKey: "CardNumber") }
        set { setFieldValue(newValue, forKey: "CardNumber", isProtected: true) }
    }

    var cardholderName: String {
        get { fieldValue(forKey: "CardholderName") }
        set { setFieldValue(newValue, forKey: "CardholderName", isProtected: false) }
    }

    var expiryDate: String {
        get { fieldValue(forKey: "ExpiryDate") }
        set { setFieldValue(newValue, forKey: "ExpiryDate", isProtected: false) }
    }

    var cvv: String {
        get { fieldValue(forKey: "CVV") }
        set { setFieldValue(newValue, forKey: "CVV", isProtected: true) }
    }

    var notesBody: String {
        get { fieldValue(forKey: "NotesBody") }
        set { setFieldValue(newValue, forKey: "NotesBody", isProtected: false) }
    }
```

Then replace the existing `standardFieldKeys` declaration:

```swift
    static let standardFieldKeys: Set<String> = ["Title", "UserName", "Password", "URL", "Notes", "otp", "Favorite"]
```

with:

```swift
    static let standardFieldKeys: Set<String> = [
        "Title", "UserName", "Password", "URL", "Notes", "otp", "Favorite",
        "MyPass.EntryType", "CardNumber", "CardholderName", "ExpiryDate", "CVV", "NotesBody"
    ]
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/KdbxEntryConvenienceTests 2>&1 | tail -50`
Expected: PASS (all `KdbxEntryConvenienceTests` tests green, including the new ones).

- [ ] **Step 6: Add a characterization round-trip test in `Packages/MyPassKit/Tests/MyPassKitTests/KdbxXmlCoderTests.swift`**

This confirms the new `MyPass.EntryType` field survives a real encode/decode cycle through `KdbxXmlCoder` exactly like any other custom string field (no `KdbxXmlCoder` production code changes are needed — this is a generic key/value field, same mechanism `Title`/`Password` already use). Add this test method after `testEncodeDecodeRoundTripWithProtectedField`:

```swift
    func testCustomEntryTypeFieldRoundTripsThroughEncodeDecode() throws {
        let entry = KdbxEntry(
            uuid: UUID(),
            iconID: 0,
            fields: [
                KdbxField(key: "Title", value: "Visa Card", isProtected: false),
                KdbxField(key: "MyPass.EntryType", value: "Card", isProtected: false)
            ],
            creationTime: Date(timeIntervalSince1970: 1_700_000_000),
            lastModificationTime: Date(timeIntervalSince1970: 1_700_000_100),
            lastAccessTime: Date(timeIntervalSince1970: 1_700_000_100),
            locationChanged: Date(timeIntervalSince1970: 1_700_000_000),
            history: []
        )
        let root = KdbxGroup(
            uuid: UUID(), name: "Root", iconID: 0,
            creationTime: Date(timeIntervalSince1970: 1_700_000_000),
            lastModificationTime: Date(timeIntervalSince1970: 1_700_000_000),
            locationChanged: Date(timeIntervalSince1970: 1_700_000_000),
            entries: [entry], subgroups: []
        )
        let payload = KdbxXmlPayload(rootGroup: root, deletedObjects: [])

        var keystreamCounter: UInt8 = 0
        func obfuscate(_ data: Data) -> Data {
            Data(data.map { byte -> UInt8 in
                keystreamCounter = keystreamCounter &+ 1
                return byte ^ keystreamCounter
            })
        }

        let xml = KdbxXmlCoder.encode(payload) { plaintext in obfuscate(plaintext) }

        keystreamCounter = 0
        let decoded = try KdbxXmlCoder.decode(xml) { ciphertext in obfuscate(ciphertext) }

        XCTAssertEqual(
            decoded.rootGroup.entries[0].fields.first(where: { $0.key == "MyPass.EntryType" })?.value,
            "Card"
        )
    }
```

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassKitTests/KdbxXmlCoderTests/testCustomEntryTypeFieldRoundTripsThroughEncodeDecode 2>&1 | tail -50`
Expected: PASS immediately (this test validates existing generic-field behavior against the new key, not new production code).

- [ ] **Step 7: Commit**

```bash
git add MyPass/Models/EntryType.swift MyPass/Models/KdbxEntry+Convenience.swift MyPassTests/KdbxEntryConvenienceTests.swift Packages/MyPassKit/Tests/MyPassKitTests/KdbxXmlCoderTests.swift
git commit -m "feat(mypass): add EntryType discriminator and Card/Notes field accessors"
```

---

### Task 2: Shared edit/detail chrome extraction

**Files:**
- Modify: `MyPass/UI/EntryDetail/EntryEditView.swift`
- Modify: `MyPass/UI/EntryDetail/EntryDetailView.swift`
- Create: `MyPass/UI/EntryDetail/EditToolbarComponents.swift`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces (used by Task 3 and Task 4):
  - `struct EntryEditFieldsCard<Content: View>: View` (widened from `private` to internal, unchanged API: `EntryEditFieldsCard { ... }`)
  - `struct DetailFieldsCard<Content: View>: View`, `struct DetailFieldRow: View { let label: String; let value: String }`, `struct DetailFieldDivider: View` (all widened from `private` to internal, unchanged APIs)
  - `struct FavoriteToggleToolbarItem: ToolbarContent { init(isFavorite: Binding<Bool>) }`
  - `struct EditActionsToolbarContent: ToolbarContent { init(onCancel: @escaping () -> Void, onSave: @escaping () -> Void) }`

There is no dedicated unit-test file for these SwiftUI views in this repo (confirmed: no `EntryEditViewTests.swift`/`EntryDetailViewTests.swift` exist). This task's correctness gate is: the app builds, the full existing test suite stays green, and a manual check that creating/editing a Login entry still shows the same Cancel/Star/Save toolbar and looks identical to before.

- [ ] **Step 1: Create `MyPass/UI/EntryDetail/EditToolbarComponents.swift`**

```swift
import SwiftUI

struct FavoriteToggleToolbarItem: ToolbarContent {
    @Binding var isFavorite: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                isFavorite.toggle()
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
            }
            .accessibilityLabel(isFavorite ? "Remove from Favorites" : "Add to Favorites")
        }
    }
}

struct EditActionsToolbarContent: ToolbarContent {
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", action: onCancel)
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Save", action: onSave)
                .keyboardShortcut(.return, modifiers: .command)
        }
    }
}
```

Note: the `.cancellationAction` placement is what already gives Cancel its Esc keyboard shortcut for free on macOS (there is no explicit `.keyboardShortcut` call for Cancel in the current code) — preserving this placement preserves the Esc behavior with no extra code.

- [ ] **Step 2: Edit `MyPass/UI/EntryDetail/EntryEditView.swift`**

Replace the `.toolbar { ... }` block (currently):

```swift
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isFavorite.toggle()
                } label: {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                }
                .accessibilityLabel(isFavorite ? "Remove from Favorites" : "Add to Favorites")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
```

with:

```swift
        .toolbar {
            EditActionsToolbarContent(onCancel: onCancel, onSave: save)
            FavoriteToggleToolbarItem(isFavorite: $isFavorite)
        }
```

Then change the `EntryEditFieldsCard` declaration at the bottom of the file from:

```swift
private struct EntryEditFieldsCard<Content: View>: View {
```

to:

```swift
struct EntryEditFieldsCard<Content: View>: View {
```

(dropping `private` so `CardEditView`/`NotesEditView` in later tasks can reuse it — everything else in that struct is unchanged.)

- [ ] **Step 3: Edit `MyPass/UI/EntryDetail/EntryDetailView.swift`**

Drop `private` from the three struct declarations near the bottom of the file (unchanged bodies otherwise):

```swift
private struct DetailFieldDivider: View {
```
→
```swift
struct DetailFieldDivider: View {
```

```swift
private struct DetailFieldRow: View {
```
→
```swift
struct DetailFieldRow: View {
```

```swift
private struct DetailFieldsCard<Content: View>: View {
```
→
```swift
struct DetailFieldsCard<Content: View>: View {
```

- [ ] **Step 4: Build and run the full existing test suite**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' 2>&1 | tail -80`
Expected: build succeeds, all existing tests still PASS (this is a pure refactor — no behavior change).

- [ ] **Step 5: Manual verification**

Launch the app (or use the `run` skill), create a new Login entry, confirm the toolbar still shows Cancel (left) / Star (right, before Save) / Save (right, ⌘Return still works, Esc still cancels) exactly as before. Edit an existing Login entry and confirm the same.

- [ ] **Step 6: Commit**

```bash
git add MyPass/UI/EntryDetail/EditToolbarComponents.swift MyPass/UI/EntryDetail/EntryEditView.swift MyPass/UI/EntryDetail/EntryDetailView.swift
git commit -m "refactor(mypass): extract shared edit/detail chrome for template reuse"
```

---

### Task 3: Card template — `CardEditView.swift` + `CardDetailView.swift`

**Files:**
- Create: `MyPass/UI/EntryDetail/CardEditView.swift`
- Create: `MyPass/UI/EntryDetail/CardDetailView.swift`

**Interfaces:**
- Consumes: `EntryType`, `KdbxEntry.cardNumber/.cardholderName/.expiryDate/.cvv/.entryType/.isFavorite/.additionalFields` (Task 1); `EntryEditFieldsCard`, `EditActionsToolbarContent`, `FavoriteToggleToolbarItem`, `DetailFieldsCard`, `DetailFieldRow`, `DetailFieldDivider` (Task 2); `GroupPickerView` (existing, unchanged); `LetterAvatarView`, `UIShellMetrics`, `LargeTypePopover`, `NSPasteboardClearing`, `RealAutoLockClock`, `ClipboardAutoClear`, `ClipboardClearInterval` (all existing, unchanged, already module-internal).
- Produces (used by Task 5):
  - `struct CardEditView: View { init(existingEntry: KdbxEntry?, rootGroup: KdbxGroup, recycleBinGroupUUID: UUID?, defaultGroupID: UUID, onCancel: @escaping () -> Void, onSave: @escaping (KdbxEntry, UUID) -> Void, onDelete: @escaping () -> Void) }` — same initializer shape as `EntryEditView`.
  - `struct CardDetailView: View { init(entry: KdbxEntry) }`.

- [ ] **Step 1: Create `MyPass/UI/EntryDetail/CardEditView.swift`**

```swift
import SwiftUI
import MyPassKit

struct CardEditView: View {
    let existingEntry: KdbxEntry?
    let rootGroup: KdbxGroup
    let recycleBinGroupUUID: UUID?
    let defaultGroupID: UUID
    let onCancel: () -> Void
    let onSave: (KdbxEntry, UUID) -> Void
    let onDelete: () -> Void

    @State private var selectedGroupID: UUID
    @State private var title: String = ""
    @State private var cardNumber: String = ""
    @State private var cardholderName: String = ""
    @State private var expiryDate: String = ""
    @State private var cvv: String = ""
    @State private var extraFields: [(key: String, value: String)] = []
    @State private var isCardNumberRevealed = false
    @State private var isCVVRevealed = false
    @State private var isFavorite: Bool

    init(
        existingEntry: KdbxEntry?,
        rootGroup: KdbxGroup,
        recycleBinGroupUUID: UUID?,
        defaultGroupID: UUID,
        onCancel: @escaping () -> Void,
        onSave: @escaping (KdbxEntry, UUID) -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.existingEntry = existingEntry
        self.rootGroup = rootGroup
        self.recycleBinGroupUUID = recycleBinGroupUUID
        self.defaultGroupID = defaultGroupID
        self.onCancel = onCancel
        self.onSave = onSave
        self.onDelete = onDelete
        _selectedGroupID = State(initialValue: defaultGroupID)
        _title = State(initialValue: existingEntry?.title ?? "")
        _cardNumber = State(initialValue: existingEntry?.cardNumber ?? "")
        _cardholderName = State(initialValue: existingEntry?.cardholderName ?? "")
        _expiryDate = State(initialValue: existingEntry?.expiryDate ?? "")
        _cvv = State(initialValue: existingEntry?.cvv ?? "")
        _extraFields = State(initialValue: (existingEntry?.additionalFields ?? [])
            .map { (key: $0.key, value: $0.value) })
        _isFavorite = State(initialValue: existingEntry?.isFavorite ?? false)
    }

    private var formattedCardNumberBinding: Binding<String> {
        Binding(
            get: {
                cardNumber.enumerated().map { index, character in
                    (index != 0 && index % 4 == 0) ? " \(character)" : String(character)
                }.joined()
            },
            set: { newValue in
                cardNumber = newValue.filter(\.isNumber)
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 12) {
                    LetterAvatarView(
                        title: title.isEmpty ? "(untitled)" : title,
                        size: UIShellMetrics.detailHeroIconSize,
                        cornerRadius: UIShellMetrics.detailHeroIconCornerRadius,
                        letterScale: UIShellMetrics.detailHeroLetterScale
                    )
                    Text(title.isEmpty ? "(untitled)" : title)
                        .font(.system(size: 22, weight: .bold))
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 24)

                EntryEditFieldsCard {
                    GroupPickerView(
                        rootGroup: rootGroup,
                        recycleBinGroupUUID: recycleBinGroupUUID,
                        selectedGroupID: $selectedGroupID
                    )
                    Divider().overlay(Color.primary.opacity(0.08))

                    TextField("Title", text: $title)
                    Divider().overlay(Color.primary.opacity(0.08))

                    HStack {
                        Group {
                            if isCardNumberRevealed {
                                TextField("Card Number", text: formattedCardNumberBinding)
                            } else {
                                SecureField("Card Number", text: formattedCardNumberBinding)
                            }
                        }
                        Button {
                            isCardNumberRevealed.toggle()
                        } label: {
                            Image(systemName: isCardNumberRevealed ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(isCardNumberRevealed ? "Hide card number" : "Show card number")
                    }
                    Divider().overlay(Color.primary.opacity(0.08))

                    TextField("Cardholder Name", text: $cardholderName)
                    Divider().overlay(Color.primary.opacity(0.08))

                    TextField("Expiry Date (MM/YY)", text: $expiryDate)
                    Divider().overlay(Color.primary.opacity(0.08))

                    HStack {
                        Group {
                            if isCVVRevealed {
                                TextField("CVV", text: $cvv)
                            } else {
                                SecureField("CVV", text: $cvv)
                            }
                        }
                        Button {
                            isCVVRevealed.toggle()
                        } label: {
                            Image(systemName: isCVVRevealed ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(isCVVRevealed ? "Hide CVV" : "Show CVV")
                    }

                    if !extraFields.isEmpty {
                        Divider().overlay(Color.primary.opacity(0.08))
                    }
                    ForEach(extraFields.indices, id: \.self) { index in
                        HStack {
                            TextField("Key", text: $extraFields[index].key)
                            TextField("Value", text: $extraFields[index].value)
                            Button("Remove", systemImage: "minus.circle") {
                                extraFields.remove(at: index)
                            }
                        }
                    }
                    Button("Add Field", systemImage: "plus") {
                        extraFields.append((key: "", value: ""))
                    }
                }

                if existingEntry != nil {
                    Button("Delete", role: .destructive, action: onDelete)
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .padding(.bottom, 24)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
        }
        .background(UIShellMetrics.detailColumnBackground)
        .navigationTitle(existingEntry == nil ? "New Card" : "Edit Card")
        .toolbar {
            EditActionsToolbarContent(onCancel: onCancel, onSave: save)
            FavoriteToggleToolbarItem(isFavorite: $isFavorite)
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
        entry.entryType = .card
        entry.title = title.isEmpty ? cardholderName : title
        entry.cardNumber = cardNumber
        entry.cardholderName = cardholderName
        entry.expiryDate = expiryDate
        entry.cvv = cvv
        entry.isFavorite = isFavorite
        entry.lastModificationTime = now
        entry.lastAccessTime = now

        entry.fields.removeAll { !KdbxEntry.standardFieldKeys.contains($0.key) }
        for field in extraFields where !field.key.isEmpty {
            entry.fields.append(KdbxField(key: field.key, value: field.value, isProtected: false))
        }

        onSave(entry, selectedGroupID)
    }
}
```

- [ ] **Step 2: Create `MyPass/UI/EntryDetail/CardDetailView.swift`**

```swift
import SwiftUI
import AppKit
import MyPassKit

struct CardDetailView: View {
    let entry: KdbxEntry
    @EnvironmentObject var vaultSession: VaultSession
    @EnvironmentObject var navigationState: NavigationState
    @State private var isCardNumberRevealed = false
    @State private var isCVVRevealed = false
    @State private var largeTypeField: LargeTypeField?

    private let pasteboard = NSPasteboardClearing()
    private let clock = RealAutoLockClock()

    private enum LargeTypeField: Equatable {
        case cardNumber
        case cvv
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 12) {
                    LetterAvatarView(
                        title: entry.title.isEmpty ? "(untitled)" : entry.title,
                        size: UIShellMetrics.detailHeroIconSize,
                        cornerRadius: UIShellMetrics.detailHeroIconCornerRadius,
                        letterScale: UIShellMetrics.detailHeroLetterScale
                    )
                    Text(entry.title.isEmpty ? "(untitled)" : entry.title)
                        .font(.system(size: 22, weight: .bold))
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 24)

                DetailFieldsCard {
                    cardNumberRow
                    DetailFieldDivider()
                    DetailFieldRow(label: "Cardholder", value: entry.cardholderName)
                    DetailFieldDivider()
                    DetailFieldRow(label: "Expiry", value: entry.expiryDate)
                    DetailFieldDivider()
                    cvvRow

                    ForEach(entry.additionalFields, id: \.key) { field in
                        DetailFieldDivider()
                        DetailFieldRow(label: field.key, value: field.value)
                            .contextMenu {
                                Button("Copy \(field.key)") { copy(field.value) }
                            }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
        }
        .background(UIShellMetrics.detailColumnBackground)
        .navigationTitle("Card")
    }

    private var cardNumberRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Card Number")
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(isCardNumberRevealed ? entry.cardNumber : String(repeating: "•", count: max(entry.cardNumber.count, 8)))
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Button {
                isCardNumberRevealed.toggle()
            } label: {
                Image(systemName: isCardNumberRevealed ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
        }
        .font(.body)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contextMenu {
            Button("Copy Card Number") { copy(entry.cardNumber) }
            Button("Show Large Type") { largeTypeField = .cardNumber }
        }
        .popover(isPresented: largeTypeBinding(.cardNumber)) {
            LargeTypePopover(text: entry.cardNumber, isMonospaced: true)
        }
    }

    private var cvvRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("CVV")
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(isCVVRevealed ? entry.cvv : String(repeating: "•", count: max(entry.cvv.count, 3)))
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Button {
                isCVVRevealed.toggle()
            } label: {
                Image(systemName: isCVVRevealed ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
        }
        .font(.body)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contextMenu {
            Button("Copy CVV") { copy(entry.cvv) }
            Button("Show Large Type") { largeTypeField = .cvv }
        }
        .popover(isPresented: largeTypeBinding(.cvv)) {
            LargeTypePopover(text: entry.cvv, isMonospaced: true)
        }
    }

    private func largeTypeBinding(_ field: LargeTypeField) -> Binding<Bool> {
        Binding(
            get: { largeTypeField == field },
            set: { isPresented in largeTypeField = isPresented ? field : nil }
        )
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        ClipboardAutoClear.schedule(value: value, after: ClipboardClearInterval.seconds(), pasteboard: pasteboard, clock: clock)
        if let id = navigationState.selectedEntryID {
            vaultSession.touchAccess(entryID: id)
        }
    }
}
```

- [ ] **Step 3: Build**

Run: `xcodebuild build -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' 2>&1 | tail -60`
Expected: build succeeds (these two views aren't wired into any navigation path yet — Task 5 does that — so this step just confirms they compile standalone).

- [ ] **Step 4: Commit**

```bash
git add MyPass/UI/EntryDetail/CardEditView.swift MyPass/UI/EntryDetail/CardDetailView.swift
git commit -m "feat(mypass): add CardEditView and CardDetailView"
```

---

### Task 4: Notes template — `NotesEditView.swift` + `NotesDetailView.swift`

**Files:**
- Create: `MyPass/UI/EntryDetail/MarkdownTextEditor.swift`
- Create: `MyPass/UI/EntryDetail/NotesEditView.swift`
- Create: `MyPass/UI/EntryDetail/NotesDetailView.swift`

**Interfaces:**
- Consumes: `EntryType`, `KdbxEntry.notesBody/.entryType/.isFavorite` (Task 1); `EntryEditFieldsCard`, `EditActionsToolbarContent`, `FavoriteToggleToolbarItem`, `DetailFieldsCard` (Task 2); `GroupPickerView`, `LetterAvatarView`, `UIShellMetrics`, `LargeTypePopover`, `NSPasteboardClearing`, `RealAutoLockClock`, `ClipboardAutoClear`, `ClipboardClearInterval` (existing).
- Produces (used by Task 5):
  - `enum MarkdownWrapAction { case wrap(prefix: String, suffix: String), linePrefix(String), insertBlock(String) }`
  - `struct MarkdownTextEditor: NSViewRepresentable { init(text: Binding<String>, wrapAction: Binding<MarkdownWrapAction?>) }`
  - `struct NotesEditView: View { init(existingEntry: KdbxEntry?, rootGroup: KdbxGroup, recycleBinGroupUUID: UUID?, defaultGroupID: UUID, onCancel: @escaping () -> Void, onSave: @escaping (KdbxEntry, UUID) -> Void, onDelete: @escaping () -> Void) }` — same initializer shape as `EntryEditView`/`CardEditView`.
  - `struct NotesDetailView: View { init(entry: KdbxEntry) }`.

Rationale for `MarkdownTextEditor` as a bespoke `NSViewRepresentable`: the app's minimum deployment target is macOS 14 (`MACOSX_DEPLOYMENT_TARGET = 14.0`), and SwiftUI's native `TextEditor(text:selection:)` selection-range API requires macOS 15+. Since the spec requires wrapping the *current text-editor selection* (not just appending to the end), a thin `NSTextView`-backed representable is the only way to reach `selectedRange()` at this deployment target — and it keeps the "no third-party markdown dependency" non-goal intact, since this is pure AppKit text manipulation, not a markdown renderer.

- [ ] **Step 1: Create `MyPass/UI/EntryDetail/MarkdownTextEditor.swift`**

```swift
import SwiftUI
import AppKit

enum MarkdownWrapAction {
    case wrap(prefix: String, suffix: String)
    case linePrefix(String)
    case insertBlock(String)
}

struct MarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var wrapAction: MarkdownWrapAction?

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.string = text
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        if let action = wrapAction {
            context.coordinator.apply(action, to: textView)
            DispatchQueue.main.async { wrapAction = nil }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let text: Binding<String>
        weak var textView: NSTextView?

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }

        func apply(_ action: MarkdownWrapAction, to textView: NSTextView) {
            let selectedRange = textView.selectedRange()
            let nsString = textView.string as NSString
            let selectedText = nsString.substring(with: selectedRange)

            switch action {
            case .wrap(let prefix, let suffix):
                let replacement = "\(prefix)\(selectedText)\(suffix)"
                textView.insertText(replacement, replacementRange: selectedRange)
                let newCursorLocation = selectedRange.location + prefix.count + selectedText.count + suffix.count
                textView.setSelectedRange(NSRange(location: newCursorLocation, length: 0))
            case .linePrefix(let prefix):
                let lineRange = nsString.lineRange(for: selectedRange)
                let line = nsString.substring(with: lineRange)
                textView.insertText(prefix + line, replacementRange: lineRange)
            case .insertBlock(let block):
                textView.insertText(block, replacementRange: selectedRange)
            }
            text.wrappedValue = textView.string
        }
    }
}
```

- [ ] **Step 2: Create `MyPass/UI/EntryDetail/NotesEditView.swift`**

```swift
import SwiftUI
import MyPassKit

struct NotesEditView: View {
    let existingEntry: KdbxEntry?
    let rootGroup: KdbxGroup
    let recycleBinGroupUUID: UUID?
    let defaultGroupID: UUID
    let onCancel: () -> Void
    let onSave: (KdbxEntry, UUID) -> Void
    let onDelete: () -> Void

    @State private var selectedGroupID: UUID
    @State private var title: String = ""
    @State private var notesBody: String = ""
    @State private var isFavorite: Bool
    @State private var pendingMarkdownAction: MarkdownWrapAction?

    init(
        existingEntry: KdbxEntry?,
        rootGroup: KdbxGroup,
        recycleBinGroupUUID: UUID?,
        defaultGroupID: UUID,
        onCancel: @escaping () -> Void,
        onSave: @escaping (KdbxEntry, UUID) -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.existingEntry = existingEntry
        self.rootGroup = rootGroup
        self.recycleBinGroupUUID = recycleBinGroupUUID
        self.defaultGroupID = defaultGroupID
        self.onCancel = onCancel
        self.onSave = onSave
        self.onDelete = onDelete
        _selectedGroupID = State(initialValue: defaultGroupID)
        _title = State(initialValue: existingEntry?.title ?? "")
        _notesBody = State(initialValue: existingEntry?.notesBody ?? "")
        _isFavorite = State(initialValue: existingEntry?.isFavorite ?? false)
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                TextField("Title", text: $title)
                    .font(.system(size: 17, weight: .semibold))
                    .textFieldStyle(.plain)
                GroupPickerView(
                    rootGroup: rootGroup,
                    recycleBinGroupUUID: recycleBinGroupUUID,
                    selectedGroupID: $selectedGroupID
                )
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)

            markdownToolbar
                .padding(.horizontal, 24)

            MarkdownTextEditor(text: $notesBody, wrapAction: $pendingMarkdownAction)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if existingEntry != nil {
                Button("Delete", role: .destructive, action: onDelete)
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .padding(.bottom, 20)
            }
        }
        .background(UIShellMetrics.detailColumnBackground)
        .navigationTitle(existingEntry == nil ? "New Note" : "Edit Note")
        .toolbar {
            EditActionsToolbarContent(onCancel: onCancel, onSave: save)
            FavoriteToggleToolbarItem(isFavorite: $isFavorite)
        }
    }

    private var markdownToolbar: some View {
        HStack(spacing: 8) {
            toolbarButton("bold", "B") { pendingMarkdownAction = .wrap(prefix: "**", suffix: "**") }
            toolbarButton("italic", "I") { pendingMarkdownAction = .wrap(prefix: "*", suffix: "*") }
            toolbarButton("underline", "U") { pendingMarkdownAction = .wrap(prefix: "<u>", suffix: "</u>") }
            Divider().frame(height: 16)
            toolbarButton("h1", "H1") { pendingMarkdownAction = .linePrefix("# ") }
            toolbarButton("h2", "H2") { pendingMarkdownAction = .linePrefix("## ") }
            toolbarButton("h3", "H3") { pendingMarkdownAction = .linePrefix("### ") }
            Divider().frame(height: 16)
            toolbarButton("hr", "HR") { pendingMarkdownAction = .insertBlock("\n---\n") }
            toolbarButton("code", "`code`") { pendingMarkdownAction = .wrap(prefix: "`", suffix: "`") }
            toolbarButton("codeblock", "```") { pendingMarkdownAction = .insertBlock("```\n\n```") }
            Spacer(minLength: 0)
        }
    }

    private func toolbarButton(_ id: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(label, action: action)
            .buttonStyle(.bordered)
            .accessibilityIdentifier("markdownToolbar.\(id)")
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
        entry.entryType = .notes
        entry.title = title
        entry.notesBody = notesBody
        entry.isFavorite = isFavorite
        entry.lastModificationTime = now
        entry.lastAccessTime = now

        entry.fields.removeAll { !KdbxEntry.standardFieldKeys.contains($0.key) }

        onSave(entry, selectedGroupID)
    }
}
```

- [ ] **Step 3: Create `MyPass/UI/EntryDetail/NotesDetailView.swift`**

```swift
import SwiftUI
import AppKit
import MyPassKit

struct NotesDetailView: View {
    let entry: KdbxEntry
    @EnvironmentObject var vaultSession: VaultSession
    @EnvironmentObject var navigationState: NavigationState
    @State private var showLargeType = false

    private let pasteboard = NSPasteboardClearing()
    private let clock = RealAutoLockClock()

    // Known limitation (accepted per spec): AttributedString(markdown:) renders
    // inline styles (bold/italic/inline code) but not block-level constructs —
    // headers/HR/code-fences remain visible as literal markdown characters.
    private var renderedBody: AttributedString {
        (try? AttributedString(markdown: entry.notesBody)) ?? AttributedString(entry.notesBody)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 12) {
                    LetterAvatarView(
                        title: entry.title.isEmpty ? "(untitled)" : entry.title,
                        size: UIShellMetrics.detailHeroIconSize,
                        cornerRadius: UIShellMetrics.detailHeroIconCornerRadius,
                        letterScale: UIShellMetrics.detailHeroLetterScale
                    )
                    Text(entry.title.isEmpty ? "(untitled)" : entry.title)
                        .font(.system(size: 22, weight: .bold))
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 24)

                DetailFieldsCard {
                    Text(renderedBody)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                .contextMenu {
                    Button("Copy Note") { copy(entry.notesBody) }
                    Button("Show Large Type") { showLargeType = true }
                }
                .popover(isPresented: $showLargeType) {
                    LargeTypePopover(text: entry.notesBody, isMonospaced: false)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
        }
        .background(UIShellMetrics.detailColumnBackground)
        .navigationTitle("Note")
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        ClipboardAutoClear.schedule(value: value, after: ClipboardClearInterval.seconds(), pasteboard: pasteboard, clock: clock)
        if let id = navigationState.selectedEntryID {
            vaultSession.touchAccess(entryID: id)
        }
    }
}
```

- [ ] **Step 4: Build**

Run: `xcodebuild build -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' 2>&1 | tail -60`
Expected: build succeeds.

- [ ] **Step 5: Commit**

```bash
git add MyPass/UI/EntryDetail/MarkdownTextEditor.swift MyPass/UI/EntryDetail/NotesEditView.swift MyPass/UI/EntryDetail/NotesDetailView.swift
git commit -m "feat(mypass): add NotesEditView, NotesDetailView, and markdown toolbar editor"
```

---

### Task 5: "+" menu, `NavigationState`, and `ContentView` routing

**Files:**
- Modify: `MyPass/State/NavigationState.swift`
- Modify: `MyPass/UI/EntryList/EntryListView.swift`
- Modify: `MyPass/ContentView.swift`

**Interfaces:**
- Consumes: `EntryType` (Task 1); `CardEditView`, `CardDetailView` (Task 3); `NotesEditView`, `NotesDetailView` (Task 4).
- Produces: widened `DetailPresentation.create(defaultGroupID: UUID?, entryType: EntryType = .login)`; widened `NavigationState.presentCreate(defaultGroupID: UUID?, entryType: EntryType = .login)`; a 3-item "Add" `Menu` in `EntryListView`; `ContentView`'s `DetailColumnView` dispatching to the correct edit/detail view based on `entryType`.

There is no dedicated unit-test file for `NavigationState.presentCreate`/`DetailPresentation` or for `ContentView`'s routing in this repo. This task's correctness gate is: the app builds, the full existing test suite stays green, and the manual verification in Step 5 below (this is also exactly the manual verification the design spec calls for).

- [ ] **Step 1: Widen `DetailPresentation` and `presentCreate` in `MyPass/State/NavigationState.swift`**

Replace:

```swift
enum DetailPresentation: Equatable, Hashable {
    case browse
    case edit(entryID: UUID)
    case create(defaultGroupID: UUID?)
    case createFromProposal(PendingSaveProposal)
}
```

with:

```swift
enum DetailPresentation: Equatable, Hashable {
    case browse
    case edit(entryID: UUID)
    case create(defaultGroupID: UUID?, entryType: EntryType = .login)
    case createFromProposal(PendingSaveProposal)
}
```

Replace:

```swift
    func presentCreate(defaultGroupID: UUID?) {
        detailPresentation = .create(defaultGroupID: defaultGroupID)
    }
```

with:

```swift
    func presentCreate(defaultGroupID: UUID?, entryType: EntryType = .login) {
        detailPresentation = .create(defaultGroupID: defaultGroupID, entryType: entryType)
    }
```

- [ ] **Step 2: Replace the "+" button with a template menu in `MyPass/UI/EntryList/EntryListView.swift`**

Replace the current toolbar item:

```swift
            ToolbarItem {
                Button("Add", systemImage: "plus") {
                    let binUUID = vaultSession.currentDatabase?.recycleBinGroupUUID
                    let defaultGroupID = GroupTreeOperations.clampedDefaultGroupID(
                        currentGroup.uuid,
                        in: rootGroup,
                        recycleBinGroupUUID: binUUID
                    )
                    navigationState.presentCreate(defaultGroupID: defaultGroupID)
                }
            }
```

with:

```swift
            ToolbarItem {
                Menu("Add", systemImage: "plus") {
                    Button("Login") { presentCreate(entryType: .login) }
                    Button("Card") { presentCreate(entryType: .card) }
                    Button("Notes") { presentCreate(entryType: .notes) }
                }
            }
```

Add this private helper method to `EntryListView` (next to the existing `toggleFavorite(_:)` helper):

```swift
    private func presentCreate(entryType: EntryType) {
        let binUUID = vaultSession.currentDatabase?.recycleBinGroupUUID
        let defaultGroupID = GroupTreeOperations.clampedDefaultGroupID(
            currentGroup.uuid,
            in: rootGroup,
            recycleBinGroupUUID: binUUID
        )
        navigationState.presentCreate(defaultGroupID: defaultGroupID, entryType: entryType)
    }
```

- [ ] **Step 3: Update `DetailColumnView` in `MyPass/ContentView.swift` to branch on `entryType`**

Replace the `body` switch:

```swift
    var body: some View {
        switch navigationState.detailPresentation {
        case .browse:
            EntryDetailView()
        case .edit(let entryID):
            entryEdit(existingID: entryID)
        case .create(let defaultGroupID):
            entryEdit(existingID: nil, defaultGroupID: defaultGroupID)
        case .createFromProposal(let proposal):
            entryEdit(existingID: nil, proposal: proposal)
        }
    }
```

with:

```swift
    var body: some View {
        switch navigationState.detailPresentation {
        case .browse:
            browseDetail()
        case .edit(let entryID):
            entryEdit(existingID: entryID)
        case .create(let defaultGroupID, let entryType):
            entryEdit(existingID: nil, defaultGroupID: defaultGroupID, entryType: entryType)
        case .createFromProposal(let proposal):
            entryEdit(existingID: nil, proposal: proposal)
        }
    }

    private var currentBrowseEntry: KdbxEntry? {
        guard let id = navigationState.selectedEntryID else { return nil }
        return EntrySearch.allEntries(in: rootGroup).first { $0.uuid == id }
    }

    @ViewBuilder
    private func browseDetail() -> some View {
        if let entry = currentBrowseEntry {
            switch entry.entryType {
            case .card:
                CardDetailView(entry: entry)
            case .notes:
                NotesDetailView(entry: entry)
            case .login:
                EntryDetailView()
            }
        } else {
            EntryDetailView()
        }
    }
```

Replace the `entryEdit(existingID:defaultGroupID:proposal:)` method:

```swift
    @ViewBuilder
    private func entryEdit(
        existingID: UUID?,
        defaultGroupID: UUID? = nil,
        proposal: PendingSaveProposal? = nil
    ) -> some View {
        let targetGroupID = resolvedDefaultGroupID(existingID: existingID, defaultGroupID: defaultGroupID)
        let existingEntry = resolvedEntry(existingID: existingID, proposal: proposal)
        EntryEditView(
            existingEntry: existingEntry,
            rootGroup: rootGroup,
            recycleBinGroupUUID: vaultSession.currentDatabase?.recycleBinGroupUUID,
            defaultGroupID: targetGroupID,
            onCancel: { navigationState.presentBrowse() },
            onSave: { saved, selectedGroupID in
                vaultSession.mutate { database in
                    if let existingID {
                        EntryPersistence.replaceEntry(saved, in: database.rootGroup)
                        if let location = GroupTreeOperations.entryLocation(entryID: existingID, in: database.rootGroup),
                           location.group.uuid != selectedGroupID {
                            GroupTreeOperations.moveEntry(withID: saved.uuid, to: selectedGroupID, in: database.rootGroup)
                        }
                    } else {
                        EntryPersistence.addEntry(saved, toGroupWithID: selectedGroupID, in: database.rootGroup)
                    }
                }
                navigationState.selectedEntryID = saved.uuid
                navigationState.presentBrowse()
            },
            onDelete: {
                guard let existingEntry else { return }
                vaultSession.mutate { database in
                    GroupTreeOperations.softDeleteEntry(
                        withID: existingEntry.uuid,
                        in: database.rootGroup,
                        deletedObjects: &database.deletedObjects,
                        recycleBinGroupUUID: &database.recycleBinGroupUUID
                    )
                }
                navigationState.selectedEntryID = nil
                navigationState.presentBrowse()
            }
        )
        .id(navigationState.detailPresentation)
    }
```

with:

```swml
    @ViewBuilder
    private func entryEdit(
        existingID: UUID?,
        defaultGroupID: UUID? = nil,
        proposal: PendingSaveProposal? = nil,
        entryType: EntryType = .login
    ) -> some View {
        let targetGroupID = resolvedDefaultGroupID(existingID: existingID, defaultGroupID: defaultGroupID)
        let existingEntry = resolvedEntry(existingID: existingID, proposal: proposal)
        let resolvedType = existingEntry?.entryType ?? entryType
        let recycleBinGroupUUID = vaultSession.currentDatabase?.recycleBinGroupUUID

        let onCancel: () -> Void = { navigationState.presentBrowse() }
        let onSave: (KdbxEntry, UUID) -> Void = { saved, selectedGroupID in
            vaultSession.mutate { database in
                if let existingID {
                    EntryPersistence.replaceEntry(saved, in: database.rootGroup)
                    if let location = GroupTreeOperations.entryLocation(entryID: existingID, in: database.rootGroup),
                       location.group.uuid != selectedGroupID {
                        GroupTreeOperations.moveEntry(withID: saved.uuid, to: selectedGroupID, in: database.rootGroup)
                    }
                } else {
                    EntryPersistence.addEntry(saved, toGroupWithID: selectedGroupID, in: database.rootGroup)
                }
            }
            navigationState.selectedEntryID = saved.uuid
            navigationState.presentBrowse()
        }
        let onDelete: () -> Void = {
            guard let existingEntry else { return }
            vaultSession.mutate { database in
                GroupTreeOperations.softDeleteEntry(
                    withID: existingEntry.uuid,
                    in: database.rootGroup,
                    deletedObjects: &database.deletedObjects,
                    recycleBinGroupUUID: &database.recycleBinGroupUUID
                )
            }
            navigationState.selectedEntryID = nil
            navigationState.presentBrowse()
        }

        switch resolvedType {
        case .login:
            EntryEditView(
                existingEntry: existingEntry, rootGroup: rootGroup,
                recycleBinGroupUUID: recycleBinGroupUUID, defaultGroupID: targetGroupID,
                onCancel: onCancel, onSave: onSave, onDelete: onDelete
            )
            .id(navigationState.detailPresentation)
        case .card:
            CardEditView(
                existingEntry: existingEntry, rootGroup: rootGroup,
                recycleBinGroupUUID: recycleBinGroupUUID, defaultGroupID: targetGroupID,
                onCancel: onCancel, onSave: onSave, onDelete: onDelete
            )
            .id(navigationState.detailPresentation)
        case .notes:
            NotesEditView(
                existingEntry: existingEntry, rootGroup: rootGroup,
                recycleBinGroupUUID: recycleBinGroupUUID, defaultGroupID: targetGroupID,
                onCancel: onCancel, onSave: onSave, onDelete: onDelete
            )
            .id(navigationState.detailPresentation)
        }
    }
```

(Note: the literal code fence above uses `swml` instead of `swift` purely as an artifact-safe marker in this plan document so the outer tool doesn't misparse nested fences — when applying this step, write it as a normal Swift file with no fence markers at all, exactly like the other steps.)

- [ ] **Step 4: Build and run the full existing test suite**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' 2>&1 | tail -80`
Expected: build succeeds, all existing tests PASS.

- [ ] **Step 5: Manual verification**

Launch the app. Click "+" — confirm the menu now shows Login / Card / Notes. Create a Card entry, confirm `CardEditView` appears, fill fields, save, confirm `CardDetailView` renders it with masked card number/CVV and working reveal/copy. Create a Notes entry, confirm `NotesEditView` appears with the markdown toolbar, use each toolbar button, save, confirm `NotesDetailView` renders bold/italic/code inline styling. Edit an existing Login entry — confirm it still opens `EntryEditView` unchanged. Open a pre-existing vault entry with no `MyPass.EntryType` field — confirm it opens as Login.

- [ ] **Step 6: Commit**

```bash
git add MyPass/State/NavigationState.swift MyPass/UI/EntryList/EntryListView.swift MyPass/ContentView.swift
git commit -m "feat(mypass): wire Login/Card/Notes template selection into add menu and routing"
```

---

### Task 6: Smart categories, sidebar, and list row icons

**Files:**
- Modify: `MyPass/UI/Shell/SmartCategory.swift`
- Modify: `MyPass/UI/EntryList/EntryCategoryFilter.swift`
- Modify: `MyPass/UI/EntryList/SmartCategoryCounts.swift`
- Modify: `MyPass/UI/EntryList/EntryListView.swift`
- Test: `MyPassTests/SmartCategoryTests.swift`
- Test: `MyPassTests/EntryCategoryFilterTests.swift`

**Interfaces:**
- Consumes: `KdbxEntry.entryType` (Task 1).
- Produces: `SmartCategory.cards`/`.notes` cases; `EntryCategoryFilter.entries(for:in:)` branches for `.cards`/`.notes`; `SmartCategoryCounts.countDisplay` branches for `.cards`/`.notes`; `EntryListRow(entryType:)` swapping in `creditcard`/`note.text` SF Symbols for Card/Notes rows.

Design note: `GroupSidebarView.swift`'s smart-category section already iterates `SmartCategory.allCases` generically (`ForEach(SmartCategory.allCases) { category in SmartCategorySidebarRow(category: category, ...) }`), so the two new cases appear in the sidebar automatically with no `GroupSidebarView.swift` changes needed. Also note the sidebar row today renders a plain colored `Circle()` driven by `category.accentColor` — there are no SF Symbols anywhere in that row (correcting an assumption in the original design spec, which described SF Symbols `creditcard`/`note.text` for the sidebar rows). To stay consistent with the sidebar's actual existing visual language, Cards/Notes get distinct `accentColor` values (matching the dot-based convention already used for Favorites/Codes/Security) rather than introducing one-off icons for only 2 of 7 rows. The `creditcard`/`note.text` SF Symbols from the spec are used instead in the entry list row icon (Step 4 below), which is the one place the spec's icon requirement is unambiguous and already icon-based (`LetterAvatarView` swap-in).

- [ ] **Step 1: Add `.cards`/`.notes` to `MyPass/UI/Shell/SmartCategory.swift`**

Replace:

```swift
enum SmartCategory: String, CaseIterable, Identifiable, Hashable {
    case all
    case favorites
    case codes
    case security
    case deleted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .favorites: return "Favorites"
        case .codes: return "Codes"
        case .security: return "Security"
        case .deleted: return "Deleted"
        }
    }

    func countDisplay(for database: KdbxDatabase) -> String {
        SmartCategoryCounts.countDisplay(for: self, database: database)
    }

    /// Accent tint for category dot and selection pill (mockup reference colors; semantic where possible).
    var accentColor: Color {
        switch self {
        case .all: return Color.accentColor
        case .favorites: return Color(red: 1.0, green: 0.8, blue: 0.0)
        case .codes: return Color.orange
        case .security: return Color.red
        case .deleted: return Color.secondary
        }
    }
}
```

with:

```swift
enum SmartCategory: String, CaseIterable, Identifiable, Hashable {
    case all
    case favorites
    case codes
    case cards
    case notes
    case security
    case deleted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .favorites: return "Favorites"
        case .codes: return "Codes"
        case .cards: return "Cards"
        case .notes: return "Notes"
        case .security: return "Security"
        case .deleted: return "Deleted"
        }
    }

    func countDisplay(for database: KdbxDatabase) -> String {
        SmartCategoryCounts.countDisplay(for: self, database: database)
    }

    /// Accent tint for category dot and selection pill (mockup reference colors; semantic where possible).
    var accentColor: Color {
        switch self {
        case .all: return Color.accentColor
        case .favorites: return Color(red: 1.0, green: 0.8, blue: 0.0)
        case .codes: return Color.orange
        case .cards: return Color.blue
        case .notes: return Color.green
        case .security: return Color.red
        case .deleted: return Color.secondary
        }
    }
}
```

- [ ] **Step 2: Update `MyPassTests/SmartCategoryTests.swift`**

Replace:

```swift
    func testAllCasesPresent() {
        XCTAssertEqual(
            Set(SmartCategory.allCases.map(\.rawValue)),
            Set(["all", "favorites", "codes", "security", "deleted"])
        )
    }

    func testTitles() {
        XCTAssertEqual(SmartCategory.all.title, "All")
        XCTAssertEqual(SmartCategory.favorites.title, "Favorites")
        XCTAssertEqual(SmartCategory.codes.title, "Codes")
        XCTAssertEqual(SmartCategory.security.title, "Security")
        XCTAssertEqual(SmartCategory.deleted.title, "Deleted")
    }
```

with:

```swift
    func testAllCasesPresent() {
        XCTAssertEqual(
            Set(SmartCategory.allCases.map(\.rawValue)),
            Set(["all", "favorites", "codes", "cards", "notes", "security", "deleted"])
        )
    }

    func testTitles() {
        XCTAssertEqual(SmartCategory.all.title, "All")
        XCTAssertEqual(SmartCategory.favorites.title, "Favorites")
        XCTAssertEqual(SmartCategory.codes.title, "Codes")
        XCTAssertEqual(SmartCategory.cards.title, "Cards")
        XCTAssertEqual(SmartCategory.notes.title, "Notes")
        XCTAssertEqual(SmartCategory.security.title, "Security")
        XCTAssertEqual(SmartCategory.deleted.title, "Deleted")
    }
```

- [ ] **Step 3: Run `SmartCategoryTests` to verify it fails, then confirm it passes after Step 1**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/SmartCategoryTests 2>&1 | tail -50`
Expected before Step 1's code change: compile error (`.cards`/`.notes` not members of `SmartCategory`); after Step 1: PASS. (Apply Step 1's `SmartCategory.swift` change now if not already applied, then re-run to confirm PASS.)

- [ ] **Step 4: Add `.cards`/`.notes` branches to `MyPass/UI/EntryList/EntryCategoryFilter.swift`**

Replace:

```swift
enum EntryCategoryFilter {
    static func entries(for category: SmartCategory, in database: KdbxDatabase) -> [KdbxEntry] {
        let all = EntrySearch.allEntries(in: database.rootGroup)
        switch category {
        case .all:
            return all.filter { !RecycleBinEntryFilter.isInRecycleBin($0, database: database) }
        case .favorites:
            return all.filter { $0.isFavorite && !RecycleBinEntryFilter.isInRecycleBin($0, database: database) }
        case .codes:
            return all.filter {
                guard let secret = $0.totpSecretBase32 else { return false }
                return !secret.isEmpty
            }
        case .security:
            return all // callers must not use Security for filtering; kept for completeness
        case .deleted:
            guard let binUUID = database.recycleBinGroupUUID,
                  let bin = database.rootGroup.subgroups.first(where: { $0.uuid == binUUID }) else { return [] }
            return bin.entries
        }
    }
}
```

with:

```swift
enum EntryCategoryFilter {
    static func entries(for category: SmartCategory, in database: KdbxDatabase) -> [KdbxEntry] {
        let all = EntrySearch.allEntries(in: database.rootGroup)
        switch category {
        case .all:
            return all.filter { !RecycleBinEntryFilter.isInRecycleBin($0, database: database) }
        case .favorites:
            return all.filter { $0.isFavorite && !RecycleBinEntryFilter.isInRecycleBin($0, database: database) }
        case .codes:
            return all.filter {
                guard let secret = $0.totpSecretBase32 else { return false }
                return !secret.isEmpty
            }
        case .cards:
            return all.filter { $0.entryType == .card && !RecycleBinEntryFilter.isInRecycleBin($0, database: database) }
        case .notes:
            return all.filter { $0.entryType == .notes && !RecycleBinEntryFilter.isInRecycleBin($0, database: database) }
        case .security:
            return all // callers must not use Security for filtering; kept for completeness
        case .deleted:
            guard let binUUID = database.recycleBinGroupUUID,
                  let bin = database.rootGroup.subgroups.first(where: { $0.uuid == binUUID }) else { return [] }
            return bin.entries
        }
    }
}
```

- [ ] **Step 5: Add tests to `MyPassTests/EntryCategoryFilterTests.swift`**

Add this helper next to `makeEntry(title:totp:)` and these two test methods at the end of the class (before the final `}`):

```swift
    private func makeEntry(title: String, entryType: EntryType) -> KdbxEntry {
        var entry = makeEntry(title: title)
        entry.entryType = entryType
        return entry
    }

    func testCardsFilterIncludesOnlyCardEntries() {
        let card = makeEntry(title: "Visa", entryType: .card)
        let login = makeEntry(title: "GitHub")
        let db = makeDatabase(rootEntries: [card, login])
        XCTAssertEqual(EntryCategoryFilter.entries(for: .cards, in: db).map(\.title), ["Visa"])
    }

    func testNotesFilterIncludesOnlyNotesEntries() {
        let note = makeEntry(title: "Wifi Password", entryType: .notes)
        let login = makeEntry(title: "GitHub")
        let db = makeDatabase(rootEntries: [note, login])
        XCTAssertEqual(EntryCategoryFilter.entries(for: .notes, in: db).map(\.title), ["Wifi Password"])
    }

    func testCardsAndNotesFiltersExcludeBin() {
        let deletedCard = makeEntry(title: "DeletedCard", entryType: .card)
        let db = makeDatabase(rootEntries: [], binEntries: [deletedCard])
        XCTAssertEqual(EntryCategoryFilter.entries(for: .cards, in: db), [])
    }
```

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/EntryCategoryFilterTests 2>&1 | tail -50`
Expected: PASS.

- [ ] **Step 6: Add `.cards`/`.notes` branches to `MyPass/UI/EntryList/SmartCategoryCounts.swift`**

Replace:

```swift
enum SmartCategoryCounts {
    static func countDisplay(for category: SmartCategory, database: KdbxDatabase) -> String {
        switch category {
        case .security:
            return "—"
        case .favorites:
            return String(favoritesCount(in: database))
        case .all:
            return String(allCount(in: database))
        case .codes:
            return String(codesCount(in: database))
        case .deleted:
            return String(deletedCount(in: database))
        }
    }

    private static func allEntries(in database: KdbxDatabase) -> [KdbxEntry] {
        EntrySearch.allEntries(in: database.rootGroup)
    }

    private static func allCount(in database: KdbxDatabase) -> Int {
        allEntries(in: database).filter { !RecycleBinEntryFilter.isInRecycleBin($0, database: database) }.count
    }

    private static func codesCount(in database: KdbxDatabase) -> Int {
        allEntries(in: database).filter {
            guard let secret = $0.totpSecretBase32 else { return false }
            return !secret.isEmpty
        }.count
    }

    private static func favoritesCount(in database: KdbxDatabase) -> Int {
        allEntries(in: database).filter {
            $0.isFavorite && !RecycleBinEntryFilter.isInRecycleBin($0, database: database)
        }.count
    }

    private static func deletedCount(in database: KdbxDatabase) -> Int {
        guard let binUUID = database.recycleBinGroupUUID,
              let bin = database.rootGroup.subgroups.first(where: { $0.uuid == binUUID }) else { return 0 }
        return bin.entries.count
    }
}
```

with:

```swift
enum SmartCategoryCounts {
    static func countDisplay(for category: SmartCategory, database: KdbxDatabase) -> String {
        switch category {
        case .security:
            return "—"
        case .favorites:
            return String(favoritesCount(in: database))
        case .all:
            return String(allCount(in: database))
        case .codes:
            return String(codesCount(in: database))
        case .cards:
            return String(cardsCount(in: database))
        case .notes:
            return String(notesCount(in: database))
        case .deleted:
            return String(deletedCount(in: database))
        }
    }

    private static func allEntries(in database: KdbxDatabase) -> [KdbxEntry] {
        EntrySearch.allEntries(in: database.rootGroup)
    }

    private static func allCount(in database: KdbxDatabase) -> Int {
        allEntries(in: database).filter { !RecycleBinEntryFilter.isInRecycleBin($0, database: database) }.count
    }

    private static func codesCount(in database: KdbxDatabase) -> Int {
        allEntries(in: database).filter {
            guard let secret = $0.totpSecretBase32 else { return false }
            return !secret.isEmpty
        }.count
    }

    private static func cardsCount(in database: KdbxDatabase) -> Int {
        allEntries(in: database).filter {
            $0.entryType == .card && !RecycleBinEntryFilter.isInRecycleBin($0, database: database)
        }.count
    }

    private static func notesCount(in database: KdbxDatabase) -> Int {
        allEntries(in: database).filter {
            $0.entryType == .notes && !RecycleBinEntryFilter.isInRecycleBin($0, database: database)
        }.count
    }

    private static func favoritesCount(in database: KdbxDatabase) -> Int {
        allEntries(in: database).filter {
            $0.isFavorite && !RecycleBinEntryFilter.isInRecycleBin($0, database: database)
        }.count
    }

    private static func deletedCount(in database: KdbxDatabase) -> Int {
        guard let binUUID = database.recycleBinGroupUUID,
              let bin = database.rootGroup.subgroups.first(where: { $0.uuid == binUUID }) else { return 0 }
        return bin.entries.count
    }
}
```

- [ ] **Step 7: Swap in template icons for Card/Notes rows in `MyPass/UI/EntryList/EntryListView.swift`**

Replace the `EntryListRow` call site:

```swift
            EntryListRow(
                title: displayTitle(for: entry),
                subtitle: entry.login
            )
```

with:

```swift
            EntryListRow(
                title: displayTitle(for: entry),
                subtitle: entry.login,
                entryType: entry.entryType
            )
```

Replace the `EntryListRow` struct:

```swift
private struct EntryListRow: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            LetterAvatarView(
                title: title,
                size: UIShellMetrics.listIconSize,
                cornerRadius: UIShellMetrics.listIconCornerRadius
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}
```

with:

```swift
private struct EntryListRow: View {
    let title: String
    let subtitle: String
    let entryType: EntryType

    var body: some View {
        HStack(spacing: 12) {
            leadingIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var leadingIcon: some View {
        switch entryType {
        case .card:
            templateIconTile(systemName: "creditcard")
        case .notes:
            templateIconTile(systemName: "note.text")
        case .login:
            LetterAvatarView(
                title: title,
                size: UIShellMetrics.listIconSize,
                cornerRadius: UIShellMetrics.listIconCornerRadius
            )
        }
    }

    private func templateIconTile(systemName: String) -> some View {
        RoundedRectangle(cornerRadius: UIShellMetrics.listIconCornerRadius, style: .continuous)
            .fill(Color.secondary.opacity(0.15))
            .frame(width: UIShellMetrics.listIconSize, height: UIShellMetrics.listIconSize)
            .overlay(
                Image(systemName: systemName)
                    .foregroundStyle(.secondary)
            )
    }
}
```

- [ ] **Step 8: Run the full test suite**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' 2>&1 | tail -80`
Expected: build succeeds, all tests PASS (including the new `SmartCategoryTests`/`EntryCategoryFilterTests` cases).

- [ ] **Step 9: Manual verification**

Launch the app. Create a Card entry and a Notes entry (per Task 5's manual check). Confirm the sidebar now shows "Cards" and "Notes" rows under Categories with live counts, and clicking each filters the list correctly. Confirm the entry list shows a credit-card icon for the Card entry and a note icon for the Notes entry, while Login entries keep their letter avatar. Open an old/pre-existing vault (or any entry created before this feature) and confirm it still shows as Login with its letter avatar, unaffected.

- [ ] **Step 10: Commit**

```bash
git add MyPass/UI/Shell/SmartCategory.swift MyPass/UI/EntryList/EntryCategoryFilter.swift MyPass/UI/EntryList/SmartCategoryCounts.swift MyPass/UI/EntryList/EntryListView.swift MyPassTests/SmartCategoryTests.swift MyPassTests/EntryCategoryFilterTests.swift
git commit -m "feat(mypass): add Cards/Notes smart categories and entry list template icons"
```
