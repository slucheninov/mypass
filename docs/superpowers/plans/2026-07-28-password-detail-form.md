# Password Detail & Edit Form Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Polish the browse detail view and visually align the edit view around the shared hero + fields-card frame, add real multi-URL storage (KDBX `StringArray`, key `KP2A_URL`) with a "Websites" management sheet, and replace the static TOTP/security-warning stubs with a live countdown ring — per `docs/superpowers/specs/2026-07-28-password-detail-form-design.md` (Approved).

**Architecture:** MyPassKit gains a small new `KdbxStringArray` model type and codec support so `KdbxXmlCoder` can round-trip a `<StringArray Key="KP2A_URL">` element alongside the existing `<String>` fields. The app layer exposes this through a new `KdbxEntry.urls` convenience property (primary `url` + `KP2A_URL` extras, deduplicated). `EntryDetailView` and `EntryEditView` (both existing SwiftUI views) are edited in place — no new screens replace them — plus four small new SwiftUI components (`TOTPCountdownRingView`, `LargeTypePopover`, `WebsitesSheet`, `EntryURLDisplay`) and one small shared helper on `GroupTreeOperations` for the Group context-menu submenu.

**Tech Stack:** Swift, SwiftUI (macOS), XCTest, Foundation `XMLDocument`/`XMLElement` (the existing hand-rolled KDBX XML codec — no XMLCoder, no third-party XML library).

## Global Constraints

- The KDBX StringArray key for additional URLs is **exactly** `KP2A_URL` — no other key is read or written for URLs (spec line 158-160, 167).
- TOTP stays hardcoded at 6 digits / 30 s period / SHA-1 — this plan does not touch `TOTPCode.parse`'s digit/period/algorithm plumbing (spec line 91-97, confirms "existing defaults").
- Countdown ring diameter: 16–18 pt (use **17 pt** exactly) (spec line 94).
- Hero letter scale for the detail-column hero avatar only: target ~55–60% of icon size (use **0.58** exactly); list-row avatars (36 pt) keep the existing `size * 0.42` ratio unchanged (spec line 62-64).
- `cardMaxWidth` (420 pt, `UIShellMetrics.swift:9`) and `detailHeroIconSize` (72 pt, `UIShellMetrics.swift:5`) are unchanged — reused as-is.
- Registrable-domain extraction stays the existing naive last-two-labels heuristic (`ExtensionEntryMatcher.registrableDomain(from:)`) — no Public Suffix List work (spec line 36, 84).
- English-only strings in source; no localization catalog work (spec line 37).
- Copy-to-clipboard "Copied" flash duration stays ~1.2 s (existing `flashCopied` behavior in `EntryDetailView.swift:350-362`, unchanged).
- No confirmation dialog is added around Delete — it keeps its current no-confirmation `role: .destructive` behavior, just relocated to edit-only (spec doesn't request one).
- Do not add: security audit UI, Share toolbar wiring, inline browse/edit merge, menu bar changes, localization catalogs, list-row inline TOTP/favicon (spec's explicit Non-goals, lines 30-38).

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `Packages/MyPassKit/Sources/MyPassKit/Model/KdbxEntry.swift` | Modify | Add `KdbxStringArray` struct + `stringArrays: [KdbxStringArray]` on `KdbxEntry` |
| `Packages/MyPassKit/Sources/MyPassKit/Format/KdbxXmlCoder.swift` | Modify | Encode/decode `<StringArray>` elements |
| `Packages/MyPassKit/Tests/MyPassKitTests/KdbxXmlCoderTests.swift` | Modify | StringArray round-trip tests |
| `MyPass/Models/KdbxEntry+Convenience.swift` | Modify | `urls` computed property, shared `standardFieldKeys`/`additionalURLsStringArrayKey` constants, `additionalFields` property |
| `MyPassTests/KdbxEntryConvenienceTests.swift` | Modify | `urls` getter/setter tests |
| `MyPass/State/ExtensionBridge/ExtensionEntryMatcher.swift` | Modify | Match against every URL in `entry.urls`, not just `entry.url` |
| `MyPassTests/ExtensionEntryMatcherTests.swift` | Modify | Multi-URL matching tests |
| `MyPass/UI/Sidebar/GroupTreeOperations.swift` | Modify | Add `selectableGroups(in:excludingRecycleBin:)` (extracted from `GroupPickerView`) |
| `MyPassTests/GroupTreeOperationsTests.swift` | Modify | Test for the new helper |
| `MyPass/UI/EntryDetail/GroupPickerView.swift` | Modify | Reuse `GroupTreeOperations.selectableGroups`, delete now-duplicated private `flatten` |
| `MyPass/UI/Shell/UIShellMetrics.swift` | Modify | Add `detailHeroLetterScale` constant |
| `MyPass/UI/Shell/LetterAvatar.swift` | Modify | `LetterAvatarView` gains a `letterScale` parameter (default preserves existing behavior) |
| `MyPass/Models/EntryURLDisplay.swift` | Create | `domain(from:)` display helper wrapping `ExtensionEntryMatcher.registrableDomain` |
| `MyPassTests/EntryURLDisplayTests.swift` | Create | Domain-helper tests |
| `MyPass/UI/EntryDetail/TOTPCountdownRingView.swift` | Create | Live green countdown ring driven by `TOTPCode.secondsRemaining` |
| `MyPassTests/TOTPCountdownRingViewTests.swift` | Create | Tests for the pure `progress(period:now:)` calculation |
| `MyPass/UI/EntryDetail/LargeTypePopover.swift` | Create | Large monospaced/rounded text popover content view |
| `MyPass/UI/EntryDetail/WebsitesSheet.swift` | Create | Add/remove/reorder URLs sheet; persists immediately via `vaultSession.mutate` |
| `MyPassTests/WebsitesSheetTests.swift` | Create | Tests for the pure `normalizedURLs(from:)` calculation |
| `MyPass/UI/EntryDetail/EntryDetailView.swift` | Modify | Row reorder, domain-only Website row, remove security stub + browse Delete, live TOTP ring, context menus, Websites sheet wiring |
| `MyPass/UI/EntryDetail/EntryEditView.swift` | Modify | Hero + card reskin, red-text Delete (edit-only), Websites entry point |
| `MyPass/ContentView.swift` | Modify | Wire a new `onDelete` closure into `EntryEditView` construction |

No new test target is created — this repo has no UI/snapshot test infrastructure (`MyPassUITests` does not exist; confirmed via full-repo search), so `EntryDetailView`/`EntryEditView` visual/interaction changes are covered by **manual verification** steps instead of automated tests, matching the spec's own "Manual verification" section and the existing precedent (`EntryEditSaveLogic` is the only piece of edit-view behavior ever extracted for unit testing).

---

### Task 1: MyPassKit — `KdbxStringArray` model

**Files:**
- Modify: `Packages/MyPassKit/Sources/MyPassKit/Model/KdbxEntry.swift`
- Test: `Packages/MyPassKit/Tests/MyPassKitTests/KdbxEntryTests.swift` (create if it does not already exist; if it exists, append)

**Interfaces:**
- Produces: `public struct KdbxStringArray: Equatable { public var key: String; public var values: [String]; public init(key: String, values: [String]) }`
- Produces: `KdbxEntry.stringArrays: [KdbxStringArray]` (new stored property, defaults to `[]` in the initializer so every existing call site across the repo keeps compiling unchanged)

- [ ] **Step 1: Write the failing test**

```swift
// Packages/MyPassKit/Tests/MyPassKitTests/KdbxEntryTests.swift
import XCTest
@testable import MyPassKit

final class KdbxEntryTests: XCTestCase {
    func testStringArraysDefaultsToEmptyAndIsSettable() {
        var entry = KdbxEntry(
            uuid: UUID(),
            iconID: 0,
            fields: [],
            creationTime: Date(),
            lastModificationTime: Date(),
            lastAccessTime: Date(),
            locationChanged: Date(),
            history: []
        )
        XCTAssertEqual(entry.stringArrays, [])

        entry.stringArrays = [KdbxStringArray(key: "KP2A_URL", values: ["https://a.example.com", "https://b.example.com"])]
        XCTAssertEqual(entry.stringArrays.first?.key, "KP2A_URL")
        XCTAssertEqual(entry.stringArrays.first?.values, ["https://a.example.com", "https://b.example.com"])
    }

    func testKdbxStringArrayEquatable() {
        let a = KdbxStringArray(key: "KP2A_URL", values: ["https://a.example.com"])
        let b = KdbxStringArray(key: "KP2A_URL", values: ["https://a.example.com"])
        let c = KdbxStringArray(key: "KP2A_URL", values: ["https://c.example.com"])
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Packages/MyPassKit --filter KdbxEntryTests`
Expected: FAIL to compile — `KdbxStringArray` and `KdbxEntry.stringArrays` do not exist yet.

- [ ] **Step 3: Write minimal implementation**

In `Packages/MyPassKit/Sources/MyPassKit/Model/KdbxEntry.swift`, add the new struct directly above `KdbxEntry` (after the existing `KdbxField` struct, i.e. after current line 17):

```swift
/// One KDBX `<StringArray>` element — a repeated-value field. MyPass currently
/// only reads/writes this shape for the `KP2A_URL` additional-URLs convention
/// (see `KdbxEntry+Convenience.urls` in the app target); unrecognized StringArray
/// keys round-trip opaquely through this same storage.
public struct KdbxStringArray: Equatable {
    public var key: String
    public var values: [String]

    public init(key: String, values: [String]) {
        self.key = key
        self.values = values
    }
}
```

Then add the stored property and initializer parameter to `KdbxEntry` (current lines 26-57):

```swift
public struct KdbxEntry: Equatable, Identifiable {
    public var uuid: UUID
    public var iconID: Int
    public var fields: [KdbxField]
    public var stringArrays: [KdbxStringArray]
    public var creationTime: Date
    public var lastModificationTime: Date
    public var lastAccessTime: Date
    public var locationChanged: Date
    public var history: [KdbxEntry]

    public init(
        uuid: UUID,
        iconID: Int,
        fields: [KdbxField],
        stringArrays: [KdbxStringArray] = [],
        creationTime: Date,
        lastModificationTime: Date,
        lastAccessTime: Date,
        locationChanged: Date,
        history: [KdbxEntry]
    ) {
        self.uuid = uuid
        self.iconID = iconID
        self.fields = fields
        self.stringArrays = stringArrays
        self.creationTime = creationTime
        self.lastModificationTime = lastModificationTime
        self.lastAccessTime = lastAccessTime
        self.locationChanged = locationChanged
        self.history = history
    }

    public var id: UUID { uuid }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path Packages/MyPassKit --filter KdbxEntryTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Packages/MyPassKit/Sources/MyPassKit/Model/KdbxEntry.swift Packages/MyPassKit/Tests/MyPassKitTests/KdbxEntryTests.swift
git commit -m "feat(mypasskit): add KdbxStringArray model for KDBX StringArray elements"
```

---

### Task 2: MyPassKit — `KdbxXmlCoder` StringArray encode/decode

**Files:**
- Modify: `Packages/MyPassKit/Sources/MyPassKit/Format/KdbxXmlCoder.swift`
- Test: `Packages/MyPassKit/Tests/MyPassKitTests/KdbxXmlCoderTests.swift`

**Interfaces:**
- Consumes: `KdbxStringArray` (Task 1), `KdbxEntry.stringArrays` (Task 1)
- Produces: `KdbxXmlCoder.encode`/`decode` now round-trip `entry.stringArrays` through `<StringArray><Key>...</Key><Value>...</Value>...</StringArray>` elements, one `<StringArray>` per array. No `Protected` attribute is ever written for these — StringArray values are always plaintext, never obfuscated.

- [ ] **Step 1: Write the failing tests**

Append to `Packages/MyPassKit/Tests/MyPassKitTests/KdbxXmlCoderTests.swift` (matching the existing `testEncodeDecodeRoundTripWithProtectedField` pattern at the top of the file):

```swift
    func testStringArrayRoundTrips() throws {
        let entry = KdbxEntry(
            uuid: UUID(),
            iconID: 0,
            fields: [KdbxField(key: "Title", value: "GitHub", isProtected: false)],
            stringArrays: [KdbxStringArray(key: "KP2A_URL", values: ["https://a.example.com", "https://b.example.com"])],
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
        let (obfuscate, deobfuscate) = passthroughStream()

        let xml = KdbxXmlCoder.encode(payload, obfuscate: obfuscate)
        let xmlString = String(data: xml, encoding: .utf8)!
        XCTAssertTrue(xmlString.contains("<StringArray>"))
        XCTAssertTrue(xmlString.contains("<Key>KP2A_URL</Key>"))
        XCTAssertTrue(xmlString.contains("https://a.example.com"))
        XCTAssertTrue(xmlString.contains("https://b.example.com"))

        let decoded = try KdbxXmlCoder.decode(xml, deobfuscate: deobfuscate)
        XCTAssertEqual(decoded.rootGroup.entries[0].stringArrays, entry.stringArrays)
    }

    func testEntryWithOnlyPrimaryUrlEmitsNoStringArrayElement() throws {
        let entry = KdbxEntry(
            uuid: UUID(), iconID: 0,
            fields: [KdbxField(key: "URL", value: "https://example.com", isProtected: false)],
            creationTime: Date(), lastModificationTime: Date(), lastAccessTime: Date(),
            locationChanged: Date(), history: []
        )
        let root = KdbxGroup(
            uuid: UUID(), name: "Root", iconID: 0,
            creationTime: Date(), lastModificationTime: Date(), locationChanged: Date(),
            entries: [entry], subgroups: []
        )
        let payload = KdbxXmlPayload(rootGroup: root, deletedObjects: [])
        let (obfuscate, _) = passthroughStream()

        let xml = KdbxXmlCoder.encode(payload, obfuscate: obfuscate)
        let xmlString = String(data: xml, encoding: .utf8)!
        XCTAssertFalse(xmlString.contains("<StringArray>"))
    }

    func testStringArrayValuesAreNotObfuscated() throws {
        let entry = KdbxEntry(
            uuid: UUID(), iconID: 0,
            fields: [],
            stringArrays: [KdbxStringArray(key: "KP2A_URL", values: ["https://plain.example.com"])],
            creationTime: Date(), lastModificationTime: Date(), lastAccessTime: Date(),
            locationChanged: Date(), history: []
        )
        let root = KdbxGroup(
            uuid: UUID(), name: "Root", iconID: 0,
            creationTime: Date(), lastModificationTime: Date(), locationChanged: Date(),
            entries: [entry], subgroups: []
        )
        let payload = KdbxXmlPayload(rootGroup: root, deletedObjects: [])
        let (obfuscate, _) = passthroughStream()

        let xml = KdbxXmlCoder.encode(payload, obfuscate: obfuscate)
        let xmlString = String(data: xml, encoding: .utf8)!
        XCTAssertTrue(xmlString.contains("https://plain.example.com"), "StringArray values must appear as plaintext, never base64-obfuscated")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Packages/MyPassKit --filter KdbxXmlCoderTests`
Expected: FAIL — encoded XML contains no `<StringArray>` element yet; `decoded.rootGroup.entries[0].stringArrays` is `[]` instead of matching.

- [ ] **Step 3: Write minimal implementation**

In `Packages/MyPassKit/Sources/MyPassKit/Format/KdbxXmlCoder.swift`, add a new private helper near `stringFieldElement` (current line 311):

```swift
private static func stringArrayElement(_ array: KdbxStringArray) -> XMLElement {
    let element = XMLElement(name: "StringArray")
    element.addChild(textElement("Key", array.key))
    for value in array.values {
        element.addChild(textElement("Value", value))
    }
    return element
}
```

In `entryElement(_:obfuscate:)` (current line 288), after the existing `fields`-encoding loop and before the `<History>` child is added, insert:

```swift
for stringArray in entry.stringArrays {
    element.addChild(stringArrayElement(stringArray))
}
```

Add a matching decode helper near the entry-level `<String>` parsing loop inside `parseEntry(_:deobfuscate:)` (current line 393). Alongside the existing `var fields: [KdbxField] = []` loop over `element.elements(forName: "String")`, add:

```swift
var stringArrays: [KdbxStringArray] = []
for arrayElement in element.elements(forName: "StringArray") {
    guard let keyElement = arrayElement.elements(forName: "Key").first,
          let key = keyElement.stringValue else {
        throw KdbxXmlCoderError.malformedXml
    }
    let values = arrayElement.elements(forName: "Value").map { $0.stringValue ?? "" }
    stringArrays.append(KdbxStringArray(key: key, values: values))
}
```

Then pass `stringArrays: stringArrays` into the `KdbxEntry(...)` constructed at the end of `parseEntry`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path Packages/MyPassKit --filter KdbxXmlCoderTests`
Expected: PASS (all three new tests plus all pre-existing tests in the file)

- [ ] **Step 5: Commit**

```bash
git add Packages/MyPassKit/Sources/MyPassKit/Format/KdbxXmlCoder.swift Packages/MyPassKit/Tests/MyPassKitTests/KdbxXmlCoderTests.swift
git commit -m "feat(mypasskit): round-trip KDBX StringArray elements through the XML codec"
```

---

### Task 3: App — `KdbxEntry.urls` convenience property

**Files:**
- Modify: `MyPass/Models/KdbxEntry+Convenience.swift`
- Test: `MyPassTests/KdbxEntryConvenienceTests.swift`

**Interfaces:**
- Consumes: `KdbxEntry.stringArrays` (Task 1), existing `KdbxEntry.url` getter/setter (`KdbxEntry+Convenience.swift:34-37`, unchanged)
- Produces: `KdbxEntry.urls: [String]` (get/set), `KdbxEntry.additionalFields: [KdbxField]`, `static KdbxEntry.standardFieldKeys: Set<String>`, `static KdbxEntry.additionalURLsStringArrayKey: String = "KP2A_URL"` — all consumed by Tasks 11-13.

- [ ] **Step 1: Write the failing tests**

Append to `MyPassTests/KdbxEntryConvenienceTests.swift`, following the file's existing `makeEmptyEntry()` + `testURLRoundTrips`-style pattern:

```swift
    func testUrlsGetterMergesPrimaryAndExtrasDeduped() {
        var entry = makeEmptyEntry()
        entry.url = "https://primary.example.com"
        entry.stringArrays = [KdbxStringArray(key: KdbxEntry.additionalURLsStringArrayKey, values: ["https://extra.example.com", "https://primary.example.com"])]

        XCTAssertEqual(entry.urls, ["https://primary.example.com", "https://extra.example.com"])
    }

    func testUrlsGetterWithNoPrimaryUsesFirstExtraAsFirstResult() {
        var entry = makeEmptyEntry()
        entry.stringArrays = [KdbxStringArray(key: KdbxEntry.additionalURLsStringArrayKey, values: ["https://only-extra.example.com"])]

        XCTAssertEqual(entry.urls, ["https://only-extra.example.com"])
    }

    func testUrlsSetterSplitsPrimaryAndExtras() {
        var entry = makeEmptyEntry()
        entry.urls = ["https://primary.example.com", "https://extra1.example.com", "https://extra2.example.com"]

        XCTAssertEqual(entry.url, "https://primary.example.com")
        XCTAssertEqual(entry.stringArrays.first?.key, KdbxEntry.additionalURLsStringArrayKey)
        XCTAssertEqual(entry.stringArrays.first?.values, ["https://extra1.example.com", "https://extra2.example.com"])
    }

    func testUrlsSetterWithEmptyArrayClearsBothPrimaryAndStringArray() {
        var entry = makeEmptyEntry()
        entry.urls = ["https://primary.example.com", "https://extra.example.com"]

        entry.urls = []

        XCTAssertEqual(entry.url, "")
        XCTAssertTrue(entry.stringArrays.isEmpty)
    }

    func testAdditionalFieldsExcludesStandardKeys() {
        var entry = makeEmptyEntry()
        entry.fields.append(KdbxField(key: "Custom Field", value: "custom value", isProtected: false))

        let keys = Set(entry.additionalFields.map(\.key))
        XCTAssertEqual(keys, ["Custom Field"])
        XCTAssertFalse(keys.contains("Title"))
        XCTAssertFalse(keys.contains("URL"))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -only-testing:MyPassTests/KdbxEntryConvenienceTests`
Expected: FAIL to compile — `KdbxEntry.urls`, `KdbxEntry.additionalFields`, and `KdbxEntry.additionalURLsStringArrayKey` do not exist yet.

- [ ] **Step 3: Write minimal implementation**

In `MyPass/Models/KdbxEntry+Convenience.swift`, add (near the existing `public extension KdbxEntry` block containing `url`):

```swift
public extension KdbxEntry {
    static let standardFieldKeys: Set<String> = ["Title", "UserName", "Password", "URL", "Notes", "otp"]
    static let additionalURLsStringArrayKey = "KP2A_URL"

    /// Primary URL (if non-empty) followed by `KP2A_URL` StringArray extras, deduplicated,
    /// order preserved. Setting the first element becomes the primary `URL` field; the
    /// remainder is stored as the `KP2A_URL` StringArray. An empty array clears both.
    var urls: [String] {
        get {
            var result: [String] = []
            if !url.isEmpty {
                result.append(url)
            }
            if let array = stringArrays.first(where: { $0.key == Self.additionalURLsStringArrayKey }) {
                for value in array.values where !result.contains(value) {
                    result.append(value)
                }
            }
            return result
        }
        set {
            var remaining = newValue
            url = remaining.isEmpty ? "" : remaining.removeFirst()
            stringArrays.removeAll { $0.key == Self.additionalURLsStringArrayKey }
            if !remaining.isEmpty {
                stringArrays.append(KdbxStringArray(key: Self.additionalURLsStringArrayKey, values: remaining))
            }
        }
    }

    /// Non-standard fields to render as browse/edit custom-field rows. `KP2A_URL` is never
    /// present here — it lives in `stringArrays`, a separate collection from `fields`.
    var additionalFields: [KdbxField] {
        fields.filter { !Self.standardFieldKeys.contains($0.key) }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -only-testing:MyPassTests/KdbxEntryConvenienceTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add MyPass/Models/KdbxEntry+Convenience.swift MyPassTests/KdbxEntryConvenienceTests.swift
git commit -m "feat(mypass): add KdbxEntry.urls multi-URL convenience API"
```

---

### Task 4: App — `ExtensionEntryMatcher` matches all URLs

**Files:**
- Modify: `MyPass/State/ExtensionBridge/ExtensionEntryMatcher.swift`
- Test: `MyPassTests/ExtensionEntryMatcherTests.swift`

**Interfaces:**
- Consumes: `KdbxEntry.urls` (Task 3)
- Produces: `ExtensionEntryMatcher.matchingEntries(in:forURL:)` unchanged signature, now matches on **every** URL in `entry.urls` instead of only `entry.url`.

- [ ] **Step 1: Write the failing test**

Append to `MyPassTests/ExtensionEntryMatcherTests.swift`, using the file's existing `makeEntry(url:title:)` / `makeGroup(entries:)` helper pattern:

```swift
    func testMatchingEntriesMatchesOnAdditionalUrlWhenPrimaryDiffers() {
        var entry = makeEntry(url: "https://primary-only.example.com", title: "Multi-URL Entry")
        entry.urls = ["https://primary-only.example.com", "https://secondary.example.com"]
        let group = makeGroup(entries: [entry])

        let matches = ExtensionEntryMatcher.matchingEntries(in: group, forURL: "https://secondary.example.com/login")

        XCTAssertEqual(matches.map(\.uuid), [entry.uuid])
    }

    func testMatchingEntriesDoesNotMatchUnrelatedDomainEvenWithExtras() {
        var entry = makeEntry(url: "https://primary-only.example.com", title: "Multi-URL Entry")
        entry.urls = ["https://primary-only.example.com", "https://secondary.example.com"]
        let group = makeGroup(entries: [entry])

        let matches = ExtensionEntryMatcher.matchingEntries(in: group, forURL: "https://totally-unrelated.example.org")

        XCTAssertTrue(matches.isEmpty)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -only-testing:MyPassTests/ExtensionEntryMatcherTests`
Expected: FAIL — `testMatchingEntriesMatchesOnAdditionalUrlWhenPrimaryDiffers` fails because current matching only inspects `entry.url`.

- [ ] **Step 3: Write minimal implementation**

In `MyPass/State/ExtensionBridge/ExtensionEntryMatcher.swift`, change `matchingEntries(in:forURL:)` so it checks every URL in `entry.urls`:

```swift
static func matchingEntries(in group: KdbxGroup, forURL urlString: String) -> [KdbxEntry] {
    guard let targetDomain = registrableDomain(from: urlString) else { return [] }
    return EntrySearch.allEntries(in: group).filter { entry in
        entry.urls.contains { registrableDomain(from: $0) == targetDomain }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -only-testing:MyPassTests/ExtensionEntryMatcherTests`
Expected: PASS (both new tests plus all pre-existing tests, including the existing empty-`url` exclusion test)

- [ ] **Step 5: Commit**

```bash
git add MyPass/State/ExtensionBridge/ExtensionEntryMatcher.swift MyPassTests/ExtensionEntryMatcherTests.swift
git commit -m "feat(mypass): match extension autofill against every entry URL, not just primary"
```

---

### Task 5: App — `GroupTreeOperations.selectableGroups` + `GroupPickerView` reuse

**Files:**
- Modify: `MyPass/UI/Sidebar/GroupTreeOperations.swift`
- Modify: `MyPass/UI/EntryDetail/GroupPickerView.swift`
- Test: `MyPassTests/GroupTreeOperationsTests.swift`

**Interfaces:**
- Produces: `GroupTreeOperations.selectableGroups(in root: KdbxGroup, excludingRecycleBin recycleBinGroupUUID: UUID?) -> [KdbxGroup]` — consumed by `GroupPickerView` (this task) and by the new Group context-menu submenu in Task 12.

- [ ] **Step 1: Write the failing test**

Append to `MyPassTests/GroupTreeOperationsTests.swift` (matching its existing fixture-building conventions for `KdbxGroup`):

```swift
    func testSelectableGroupsExcludesRecycleBinButIncludesEverythingElse() {
        let recycleBin = KdbxGroup(
            uuid: UUID(), name: "Recycle Bin", iconID: 0,
            creationTime: Date(), lastModificationTime: Date(), locationChanged: Date(),
            entries: [], subgroups: []
        )
        let child = KdbxGroup(
            uuid: UUID(), name: "Work", iconID: 0,
            creationTime: Date(), lastModificationTime: Date(), locationChanged: Date(),
            entries: [], subgroups: []
        )
        let root = KdbxGroup(
            uuid: UUID(), name: "Root", iconID: 0,
            creationTime: Date(), lastModificationTime: Date(), locationChanged: Date(),
            entries: [], subgroups: [child, recycleBin]
        )

        let selectable = GroupTreeOperations.selectableGroups(in: root, excludingRecycleBin: recycleBin.uuid)

        XCTAssertEqual(Set(selectable.map(\.uuid)), [root.uuid, child.uuid])
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -only-testing:MyPassTests/GroupTreeOperationsTests`
Expected: FAIL to compile — `GroupTreeOperations.selectableGroups` does not exist yet.

- [ ] **Step 3: Write minimal implementation**

In `MyPass/UI/Sidebar/GroupTreeOperations.swift`, add (near the other group-tree helpers, e.g. next to `isTheRecycleBin`):

```swift
static func selectableGroups(in root: KdbxGroup, excludingRecycleBin recycleBinGroupUUID: UUID?) -> [KdbxGroup] {
    flattenGroups(root).filter { !isTheRecycleBin($0, recycleBinGroupUUID: recycleBinGroupUUID) }
}

private static func flattenGroups(_ group: KdbxGroup) -> [KdbxGroup] {
    [group] + group.subgroups.flatMap(flattenGroups)
}
```

Then in `MyPass/UI/EntryDetail/GroupPickerView.swift`, replace the existing private `selectableGroups` computed property and `flatten(_:)` function (current lines 18-26) with:

```swift
private var selectableGroups: [KdbxGroup] {
    GroupTreeOperations.selectableGroups(in: rootGroup, excludingRecycleBin: recycleBinGroupUUID)
}
```

(Delete the now-unused private `flatten(_:)` function entirely — its logic moved to `GroupTreeOperations.flattenGroups`.)

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -only-testing:MyPassTests/GroupTreeOperationsTests`
Expected: PASS. Also manually verify `GroupPickerView`'s existing `Picker` in the edit form still lists the same groups as before (build & open Edit on any entry — group dropdown unchanged).

- [ ] **Step 5: Commit**

```bash
git add MyPass/UI/Sidebar/GroupTreeOperations.swift MyPass/UI/EntryDetail/GroupPickerView.swift MyPassTests/GroupTreeOperationsTests.swift
git commit -m "refactor(mypass): extract selectableGroups onto GroupTreeOperations for reuse"
```

---

### Task 6: App — Detail hero letter scale

**Files:**
- Modify: `MyPass/UI/Shell/UIShellMetrics.swift`
- Modify: `MyPass/UI/Shell/LetterAvatar.swift`

**Interfaces:**
- Produces: `UIShellMetrics.detailHeroLetterScale: CGFloat = 0.58`; `LetterAvatarView` gains `var letterScale: CGFloat = 0.42` (default matches current behavior exactly, so all existing 36 pt list-row call sites are unaffected without any changes to their call sites).

There is no automated test for this step — `LetterAvatarTests.swift` only tests the pure `LetterAvatar.letter(from:)` / `.color(for:)` hashing functions, and this repo has no SwiftUI rendering/snapshot test infrastructure to assert on rendered font size. Verify manually per Step 3.

- [ ] **Step 1: Add the metric**

In `MyPass/UI/Shell/UIShellMetrics.swift`, add next to `detailHeroIconSize` (current line 5):

```swift
static let detailHeroLetterScale: CGFloat = 0.58
```

- [ ] **Step 2: Add the parameter to `LetterAvatarView`**

In `MyPass/UI/Shell/LetterAvatar.swift`, change the view (current lines 21-37):

```swift
struct LetterAvatarView: View {
    let title: String
    let size: CGFloat
    let cornerRadius: CGFloat
    var letterScale: CGFloat = 0.42

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(LetterAvatar.color(for: title))
            Text(LetterAvatar.letter(from: title))
                .font(.system(size: size * letterScale, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityLabel(Text("Icon for \(title.isEmpty ? "untitled entry" : title)"))
    }
}
```

(Only the `letterScale` property and its use in `.font(size:)` are new; every other line is unchanged from the current file.)

- [ ] **Step 3: Manual verification**

Build and run the app (`xcodebuild -project MyPass.xcodeproj -scheme MyPass build` then launch, or use the `run` skill). Select any entry in browse. Confirm the hero avatar's letter now visually fills more of the rounded square (~55-60% of the icon height) compared to before. Confirm sidebar/list-row avatars (36 pt) are visually unchanged, since Task 11/13 will pass `letterScale: UIShellMetrics.detailHeroLetterScale` explicitly only at the two detail-hero call sites, leaving every list-row `LetterAvatarView(...)` call site (which omits `letterScale`) on the unchanged 0.42 default.

- [ ] **Step 4: Commit**

```bash
git add MyPass/UI/Shell/UIShellMetrics.swift MyPass/UI/Shell/LetterAvatar.swift
git commit -m "feat(mypass): add configurable detail-hero letter scale to LetterAvatarView"
```

---

### Task 7: App — `EntryURLDisplay` domain helper

**Files:**
- Create: `MyPass/Models/EntryURLDisplay.swift`
- Test: `MyPassTests/EntryURLDisplayTests.swift`

**Interfaces:**
- Consumes: `ExtensionEntryMatcher.registrableDomain(from:)` (existing, unchanged)
- Produces: `EntryURLDisplay.domain(from: String) -> String?` — consumed by Task 11 (browse Website row).

- [ ] **Step 1: Write the failing test**

```swift
// MyPassTests/EntryURLDisplayTests.swift
import XCTest
@testable import MyPass

final class EntryURLDisplayTests: XCTestCase {
    func testDomainStripsSchemePathAndQuery() {
        XCTAssertEqual(EntryURLDisplay.domain(from: "https://login.example.com/path?q=1"), "example.com")
    }

    func testDomainFromBareHostWithSuffix() {
        XCTAssertEqual(EntryURLDisplay.domain(from: "example.co.uk"), "example.co.uk")
    }

    func testDomainFromEmptyStringIsNil() {
        XCTAssertNil(EntryURLDisplay.domain(from: ""))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -only-testing:MyPassTests/EntryURLDisplayTests`
Expected: FAIL to compile — `EntryURLDisplay` does not exist yet.

- [ ] **Step 3: Write minimal implementation**

```swift
// MyPass/Models/EntryURLDisplay.swift
import Foundation

/// Domain-only display text for a stored URL (e.g. the browse Website row). Delegates
/// to `ExtensionEntryMatcher.registrableDomain`, which documents the naive
/// last-two-DNS-labels heuristic this app uses (no Public Suffix List).
enum EntryURLDisplay {
    static func domain(from urlString: String) -> String? {
        ExtensionEntryMatcher.registrableDomain(from: urlString)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -only-testing:MyPassTests/EntryURLDisplayTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add MyPass/Models/EntryURLDisplay.swift MyPassTests/EntryURLDisplayTests.swift
git commit -m "feat(mypass): add EntryURLDisplay domain-only display helper"
```

---

### Task 8: App — `TOTPCountdownRingView`

**Files:**
- Create: `MyPass/UI/EntryDetail/TOTPCountdownRingView.swift`
- Test: `MyPassTests/TOTPCountdownRingViewTests.swift`

**Interfaces:**
- Consumes: `TOTPCode.secondsRemaining(period:now:)` (existing, `MyPass/Models/TOTPCode.swift:78-82`, currently unused anywhere in the app)
- Produces: `TOTPCountdownRingView(period: TimeInterval, now: Date, diameter: CGFloat = 17)` view; `TOTPCountdownRingView.progress(period:now:) -> Double` (static, pure, testable) — consumed by Task 11 (replaces `TOTPRingChrome`).

- [ ] **Step 1: Write the failing test**

```swift
// MyPassTests/TOTPCountdownRingViewTests.swift
import XCTest
@testable import MyPass

final class TOTPCountdownRingViewTests: XCTestCase {
    func testProgressIsFullAtStartOfPeriod() {
        let periodStart = Date(timeIntervalSince1970: 1_700_000_000) // divisible by 30
        let progress = TOTPCountdownRingView.progress(period: 30, now: periodStart)
        XCTAssertEqual(progress, 1.0, accuracy: 0.001)
    }

    func testProgressIsHalfAtMidpoint() {
        let midpoint = Date(timeIntervalSince1970: 1_700_000_015)
        let progress = TOTPCountdownRingView.progress(period: 30, now: midpoint)
        XCTAssertEqual(progress, 0.5, accuracy: 0.001)
    }

    func testProgressStaysWithinZeroToOne() {
        for offset in stride(from: 0.0, to: 30.0, by: 3.0) {
            let now = Date(timeIntervalSince1970: 1_700_000_000 + offset)
            let progress = TOTPCountdownRingView.progress(period: 30, now: now)
            XCTAssertGreaterThanOrEqual(progress, 0.0)
            XCTAssertLessThanOrEqual(progress, 1.0)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -only-testing:MyPassTests/TOTPCountdownRingViewTests`
Expected: FAIL to compile — `TOTPCountdownRingView` does not exist yet.

- [ ] **Step 3: Write minimal implementation**

```swift
// MyPass/UI/EntryDetail/TOTPCountdownRingView.swift
import SwiftUI

/// Live green countdown ring for the browse TOTP row, replacing the old static
/// `TOTPRingChrome`. Ticks alongside the parent view's existing 1 s timer.
struct TOTPCountdownRingView: View {
    let period: TimeInterval
    let now: Date
    var diameter: CGFloat = 17

    static func progress(period: TimeInterval, now: Date) -> Double {
        guard period > 0 else { return 0 }
        return TOTPCode.secondsRemaining(period: period, now: now) / period
    }

    var body: some View {
        Circle()
            .trim(from: 0, to: Self.progress(period: period, now: now))
            .stroke(Color.green, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .frame(width: diameter, height: diameter)
            .animation(.linear(duration: 1), value: now)
            .accessibilityHidden(true)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -only-testing:MyPassTests/TOTPCountdownRingViewTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add MyPass/UI/EntryDetail/TOTPCountdownRingView.swift MyPassTests/TOTPCountdownRingViewTests.swift
git commit -m "feat(mypass): add live TOTP countdown ring view"
```

---

### Task 9: App — `LargeTypePopover`

**Files:**
- Create: `MyPass/UI/EntryDetail/LargeTypePopover.swift`

**Interfaces:**
- Produces: `LargeTypePopover(text: String, isMonospaced: Bool = true)` view — consumed by Task 12 (Username/Password/Verification Code "Show Large Type" context-menu items).

No automated test — this is a pure display `View` with no branching logic and no SwiftUI test infrastructure exists in this repo to assert on it. Verified manually in Task 12's manual-verification step, where all three "Show Large Type" call sites are wired up.

- [ ] **Step 1: Write the component**

```swift
// MyPass/UI/EntryDetail/LargeTypePopover.swift
import SwiftUI

/// Large-text popover content shown from a field row's "Show Large Type" context
/// menu item. The caller is responsible for supplying already-cleartext `text` —
/// this view has no reveal/mask logic of its own.
struct LargeTypePopover: View {
    let text: String
    var isMonospaced: Bool = true

    var body: some View {
        Text(text)
            .font(.system(size: 48, weight: .medium, design: isMonospaced ? .monospaced : .rounded))
            .padding(32)
            .frame(minWidth: 200)
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add MyPass/UI/EntryDetail/LargeTypePopover.swift
git commit -m "feat(mypass): add LargeTypePopover for Show Large Type context menu action"
```

---

### Task 10: App — `WebsitesSheet`

**Files:**
- Create: `MyPass/UI/EntryDetail/WebsitesSheet.swift`
- Test: `MyPassTests/WebsitesSheetTests.swift`

**Interfaces:**
- Consumes: `KdbxEntry.urls` (Task 3), `VaultSession.mutate(_:)` (existing, `MyPass/State/VaultSession.swift:113-118`), `GroupTreeOperations.entryLocation(entryID:in:)` (existing, `MyPass/UI/Sidebar/GroupTreeOperations.swift:70`)
- Produces: `WebsitesSheet(entryID: UUID, entryTitle: String, initialURLs: [String], onDone: @escaping ([String]) -> Void, onCancel: @escaping () -> Void)` — consumed by Task 12 (browse "Change Website") and Task 13 (edit "Edit Websites…"). `WebsitesSheet.normalizedURLs(from: [String]) -> [String]` (static, pure, testable).

- [ ] **Step 1: Write the failing test**

```swift
// MyPassTests/WebsitesSheetTests.swift
import XCTest
@testable import MyPass

final class WebsitesSheetTests: XCTestCase {
    func testNormalizedURLsTrimsWhitespaceAndDropsBlankRows() {
        let result = WebsitesSheet.normalizedURLs(from: ["  https://a.example.com  ", "", "   ", "https://b.example.com"])
        XCTAssertEqual(result, ["https://a.example.com", "https://b.example.com"])
    }

    func testNormalizedURLsWithAllBlankRowsIsEmpty() {
        XCTAssertEqual(WebsitesSheet.normalizedURLs(from: ["", "  "]), [])
    }

    func testNormalizedURLsPreservesOrder() {
        XCTAssertEqual(
            WebsitesSheet.normalizedURLs(from: ["https://z.example.com", "https://a.example.com"]),
            ["https://z.example.com", "https://a.example.com"]
        )
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -only-testing:MyPassTests/WebsitesSheetTests`
Expected: FAIL to compile — `WebsitesSheet` does not exist yet.

- [ ] **Step 3: Write minimal implementation**

```swift
// MyPass/UI/EntryDetail/WebsitesSheet.swift
import SwiftUI
import MyPassKit

/// Apple Passwords–style URL editor, shared by browse ("Change Website" context menu)
/// and edit ("Edit Websites…"). Persists immediately via `vaultSession.mutate` on
/// Done — it does not wait for the caller's own Save. List order is authoritative:
/// after trimming and dropping blank rows, the first remaining row becomes the
/// primary `URL`; the rest become the `KP2A_URL` StringArray extras.
struct WebsitesSheet: View {
    let entryID: UUID
    let entryTitle: String
    let onDone: ([String]) -> Void
    let onCancel: () -> Void

    @EnvironmentObject private var vaultSession: VaultSession
    @State private var rows: [String]

    init(
        entryID: UUID,
        entryTitle: String,
        initialURLs: [String],
        onDone: @escaping ([String]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.entryID = entryID
        self.entryTitle = entryTitle
        self.onDone = onDone
        self.onCancel = onCancel
        _rows = State(initialValue: initialURLs.isEmpty ? [""] : initialURLs)
    }

    static func normalizedURLs(from rows: [String]) -> [String] {
        rows
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Websites")
                .font(.title3.bold())
            Text("These websites will be used to autofill **\(entryTitle)**.")
                .font(.callout)
                .foregroundStyle(.secondary)

            List {
                ForEach(rows.indices, id: \.self) { index in
                    HStack {
                        Text(index == 0 ? "Primary" : "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .leading)
                        TextField("https://example.com", text: $rows[index])
                        Button("Remove", systemImage: "minus.circle") {
                            rows.remove(at: index)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    }
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 120, maxHeight: 240)

            Button("Add Website", systemImage: "plus") {
                rows.append("")
            }
            .labelStyle(.iconOnly)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Done", action: done)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func done() {
        let trimmed = Self.normalizedURLs(from: rows)
        vaultSession.mutate { database in
            guard let location = GroupTreeOperations.entryLocation(entryID: entryID, in: database.rootGroup) else { return }
            location.group.entries[location.index].urls = trimmed
            location.group.entries[location.index].lastModificationTime = Date()
        }
        onDone(trimmed)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -only-testing:MyPassTests/WebsitesSheetTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add MyPass/UI/EntryDetail/WebsitesSheet.swift MyPassTests/WebsitesSheetTests.swift
git commit -m "feat(mypass): add WebsitesSheet for multi-URL add/remove/reorder"
```

---

### Task 11: App — `EntryDetailView` row reorder, domain-only Website, remove stubs, live TOTP ring

**Files:**
- Modify: `MyPass/UI/EntryDetail/EntryDetailView.swift`

**Interfaces:**
- Consumes: `KdbxEntry.urls`/`additionalFields`/`standardFieldKeys` (Task 3), `EntryURLDisplay.domain(from:)` (Task 7), `TOTPCountdownRingView` (Task 8), `UIShellMetrics.detailHeroLetterScale` (Task 6)
- Produces: reordered `body` row layout, `websiteRow(for:)` — consumed by Task 12, which attaches context menus to these same call sites.

This task is purely structural (order, display, stub removal) — context menus, popovers, and the Websites sheet trigger are added on top in Task 12 so each task stays independently reviewable. There is no automated test for this step (no SwiftUI test infra in this repo); verify manually per Step 5.

- [ ] **Step 1: Remove the private duplicated `standardFieldKeys`/`additionalFields`, use the shared ones from Task 3**

Delete the private declarations at current lines 52 and 76-78:

```swift
private static let standardFieldKeys: Set<String> = ["Title", "UserName", "Password", "URL", "Notes", "otp"]
```

and

```swift
private func additionalFields(for entry: KdbxEntry) -> [KdbxField] {
    entry.fields.filter { !Self.standardFieldKeys.contains($0.key) }
}
```

Every call site that referenced `additionalFields(for: entry)` now reads `entry.additionalFields` instead (see Step 3 below).

- [ ] **Step 2: Remove `SecurityWarningStubView` and the browse Delete button**

Delete the `SecurityWarningStubView()` call at current line 145, and delete the entire private struct definition at current lines 461-481.

Replace the `HStack` at current lines 147-165 (which branches between Restore and Delete) with **Restore only**:

```swift
if isInRecycleBin(entry) {
    HStack {
        Button("Restore") {
            vaultSession.mutate { database in
                GroupTreeOperations.restoreEntry(withID: entry.uuid, to: database.rootGroup.uuid, in: database.rootGroup)
            }
            navigationState.selectedEntryID = nil
        }
    }
    .padding(.bottom, 24)
}
```

(The destructive `Button("Delete", role: .destructive)` branch is deleted entirely — Delete moves to `EntryEditView` in Task 13.)

- [ ] **Step 3: Reorder rows and add the domain-only Website row**

Replace the `DetailFieldsCard { ... }` block (current lines 96-139) with this row order — Username, Password, Verification Code, Website, Group, Modified, Notes, then custom fields last:

```swift
DetailFieldsCard {
    copyableFieldRow(
        label: "Username",
        field: .username,
        displayValue: entry.login,
        copyValue: entry.login
    )

    DetailFieldDivider()

    passwordRow(for: entry)

    if let secret = entry.totpSecretBase32 {
        DetailFieldDivider()
        totpRow(secret: secret)
    }

    if !entry.urls.isEmpty {
        DetailFieldDivider()
        websiteRow(for: entry)
    }

    if let groupName = groupName(for: entry) {
        DetailFieldDivider()
        DetailFieldRow(label: "Group", value: groupName)
    }

    DetailFieldDivider()

    DetailFieldRow(
        label: "Modified",
        value: entry.lastModificationTime.formatted(date: .abbreviated, time: .shortened)
    )

    if !entry.notes.isEmpty {
        DetailFieldDivider()
        DetailFieldRow(label: "Notes", value: entry.notes)
    }

    ForEach(entry.additionalFields, id: \.key) { field in
        DetailFieldDivider()
        extraFieldRow(field)
    }
}
```

Add the new `websiteRow(for:)` function near `passwordRow(for:)`:

```swift
private func websiteRow(for entry: KdbxEntry) -> some View {
    let domain = EntryURLDisplay.domain(from: entry.url) ?? entry.url

    return HStack(alignment: .firstTextBaseline, spacing: 12) {
        Text("Website")
            .foregroundStyle(.secondary)
            .frame(width: 100, alignment: .leading)
        Text(domain)
            .foregroundStyle(Color.accentColor)
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .font(.body)
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
}
```

Delete the now-unused `isLink` parameter and its `Link`-rendering branch from `DetailFieldRow` (current lines 406-430), since `websiteRow(for:)` is now the only Website renderer:

```swift
private struct DetailFieldRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.body)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
```

- [ ] **Step 4: Swap in the live TOTP ring and the detail hero letter scale**

In `totpRow(secret:)` (current lines 320-348), replace `TOTPRingChrome()` with `TOTPCountdownRingView(period: 30, now: now)`:

```swift
private func totpRow(secret: String) -> some View {
    let code = currentTOTPCode(secret: secret)
    let displayValue = copiedField == .totp ? "Copied" : code

    return HStack(alignment: .center, spacing: 12) {
        Text("Verification Code")
            .foregroundStyle(.secondary)
            .frame(width: 100, alignment: .leading)
        Button {
            copy(code)
            flashCopied(.totp)
        } label: {
            HStack(spacing: 8) {
                Text(displayValue)
                    .font(.system(.body, design: .monospaced))
                if copiedField != .totp {
                    TOTPCountdownRingView(period: 30, now: now)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Click to copy")
    }
    .font(.body)
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
}

private func currentTOTPCode(secret: String) -> String {
    TOTPCode.currentCode(secretBase32: secret, digits: 6, period: 30, algorithm: .sha1, now: now) ?? "------"
}
```

(`currentTOTPCode(secret:)` is a small extraction so Task 12's context-menu/popover code doesn't re-duplicate the hardcoded `digits: 6, period: 30, algorithm: .sha1` a third time.)

Delete the now-unused private `TOTPRingChrome` struct (current lines 452-459).

In the hero `LetterAvatarView(...)` call (current lines 85-89), pass the new scale:

```swift
LetterAvatarView(
    title: entry.title.isEmpty ? "(untitled)" : entry.title,
    size: UIShellMetrics.detailHeroIconSize,
    cornerRadius: UIShellMetrics.detailHeroIconCornerRadius,
    letterScale: UIShellMetrics.detailHeroLetterScale
)
```

- [ ] **Step 5: Manual verification**

Build and run the app. For an entry with a TOTP secret and a URL:
- Confirm row order top-to-bottom: Username, Password, Verification Code, Website, Group, Modified, (Notes if present), (custom fields last, if any).
- Confirm the Website row shows only the domain (e.g. `example.com`), not the full URL, and is accent-colored.
- Confirm the TOTP ring now animates a green countdown (not a static gray circle) and shrinks/grows over ~30 s, hiding during the "Copied" flash.
- Confirm there is no "Security warning (coming later)" placeholder anywhere in browse.
- Confirm there is no Delete button in browse for a non-recycled entry; confirm Restore still appears for a recycled entry.
- Confirm the hero avatar letter is visually larger/more filled than before.

- [ ] **Step 6: Commit**

```bash
git add MyPass/UI/EntryDetail/EntryDetailView.swift
git commit -m "feat(mypass): reorder browse fields, show domain-only Website row, live TOTP ring, remove stubs"
```

---

### Task 12: App — `EntryDetailView` context menus, Show Large Type, Websites sheet, Group move

**Files:**
- Modify: `MyPass/UI/EntryDetail/EntryDetailView.swift`

**Interfaces:**
- Consumes: `LargeTypePopover` (Task 9), `WebsitesSheet` (Task 10), `GroupTreeOperations.selectableGroups` (Task 5), `GroupTreeOperations.moveEntry(withID:to:in:)` (existing, `GroupTreeOperations.swift:57-68`)

There is no automated test for this step (interaction-only SwiftUI behavior, no test infra); verify manually per Step 6.

- [ ] **Step 1: Add state for Show Large Type and the Websites sheet**

Near the existing `@State` declarations at the top of `EntryDetailView` (current lines 33-39), add:

```swift
@State private var largeTypeField: LargeTypeField?
@State private var showWebsitesSheet = false
```

Add the new private enum near `CopiedField` (current lines 45-50):

```swift
private enum LargeTypeField: Equatable {
    case username
    case password
    case totp
}
```

Add a helper binding function near `flashCopied`/`copy` (current lines 350-371):

```swift
private func largeTypeBinding(_ field: LargeTypeField) -> Binding<Bool> {
    Binding(
        get: { largeTypeField == field },
        set: { isPresented in largeTypeField = isPresented ? field : nil }
    )
}

private func openWebsite(_ urlString: String) {
    let normalized = urlString.contains("://") ? urlString : "https://\(urlString)"
    guard let url = URL(string: normalized) else { return }
    NSWorkspace.shared.open(url)
}

private func moveToGroup(_ groupID: UUID, entryID: UUID) {
    vaultSession.mutate { database in
        GroupTreeOperations.moveEntry(withID: entryID, to: groupID, in: database.rootGroup)
    }
}
```

- [ ] **Step 2: Wire Username context menu + Show Large Type**

At the Username call site inside `DetailFieldsCard` (from Task 11's Step 3), attach:

```swift
copyableFieldRow(
    label: "Username",
    field: .username,
    displayValue: entry.login,
    copyValue: entry.login
)
.contextMenu {
    Button("Copy Username") {
        copy(entry.login)
        flashCopied(.username)
    }
    Button("Show Large Type") {
        largeTypeField = .username
    }
}
.popover(isPresented: largeTypeBinding(.username)) {
    LargeTypePopover(text: entry.login, isMonospaced: false)
}
```

- [ ] **Step 3: Wire Password context menu + Show Large Type (always cleartext)**

At the `passwordRow(for: entry)` call site, attach:

```swift
passwordRow(for: entry)
    .contextMenu {
        Button("Copy Password") {
            copy(entry.password)
            flashCopied(.password)
        }
        Button("Show Large Type") {
            largeTypeField = .password
        }
    }
    .popover(isPresented: largeTypeBinding(.password)) {
        LargeTypePopover(text: entry.password)
    }
```

- [ ] **Step 4: Wire Verification Code context menu + Show Large Type (live)**

At the `totpRow(secret: secret)` call site (inside the `if let secret = entry.totpSecretBase32` block), attach:

```swift
totpRow(secret: secret)
    .contextMenu {
        Button("Copy Code") {
            copy(currentTOTPCode(secret: secret))
            flashCopied(.totp)
        }
        Button("Show Large Type") {
            largeTypeField = .totp
        }
    }
    .popover(isPresented: largeTypeBinding(.totp)) {
        LargeTypePopover(text: currentTOTPCode(secret: secret))
    }
```

(`LargeTypePopover`'s `text:` is recomputed on every SwiftUI re-render, and `EntryDetailView` already re-renders every second via its existing `now` timer — this is what keeps the popover's TOTP code live without any extra plumbing.)

- [ ] **Step 5: Wire Website context menu (Open/Copy/Change) and Group submenu (immediate move)**

At the `websiteRow(for: entry)` call site (from Task 11), attach:

```swift
websiteRow(for: entry)
    .contextMenu {
        Button("Open Website") { openWebsite(entry.url) }
        Button("Copy Website") { copy(entry.url) }
        Button("Change Website") { showWebsitesSheet = true }
    }
```

At the `DetailFieldRow(label: "Group", value: groupName)` call site, attach:

```swift
DetailFieldRow(label: "Group", value: groupName)
    .contextMenu {
        if let database = vaultSession.currentDatabase {
            let groups = GroupTreeOperations.selectableGroups(in: database.rootGroup, excludingRecycleBin: database.recycleBinGroupUUID)
            let currentGroupID = GroupTreeOperations.entryLocation(entryID: entry.uuid, in: database.rootGroup)?.group.uuid
            ForEach(groups, id: \.uuid) { group in
                Button {
                    moveToGroup(group.uuid, entryID: entry.uuid)
                } label: {
                    HStack {
                        Text(group.name)
                        if group.uuid == currentGroupID {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }
    }
```

- [ ] **Step 6: Present the Websites sheet**

Add near the existing `.sheet(isPresented: $showHistory) { ... }` modifier (current lines 180-196):

```swift
.sheet(isPresented: $showWebsitesSheet) {
    WebsitesSheet(
        entryID: entry.uuid,
        entryTitle: entry.title,
        initialURLs: entry.urls,
        onDone: { _ in showWebsitesSheet = false },
        onCancel: { showWebsitesSheet = false }
    )
}
```

- [ ] **Step 7: Manual verification**

Build and run the app.
- Right-click Username/Password/Verification Code rows: confirm "Copy X" and "Show Large Type" appear; confirm no menu appears on plain left-click (unchanged); confirm double-click does nothing new.
- Click "Show Large Type" on Password: confirm the popover always shows cleartext even when browse's own eye-toggle has the row masked.
- Click "Show Large Type" on Verification Code: confirm the code visibly changes at the next 30 s boundary while the popover stays open.
- Right-click Website row: confirm "Open Website" opens the default browser to the full primary URL, "Copy Website" puts the full URL (not the domain) on the pasteboard, "Change Website" opens the Websites sheet.
- In the Websites sheet, add a second URL and click Done: confirm the change is visible immediately in browse without opening Edit or clicking any Save button.
- Right-click Group row: confirm a submenu lists every group except Recycle Bin, with a checkmark next to the current group; selecting a different group moves the entry immediately (list/sidebar reflects the move without opening Edit).

- [ ] **Step 8: Commit**

```bash
git add MyPass/UI/EntryDetail/EntryDetailView.swift
git commit -m "feat(mypass): add browse context menus, Show Large Type, Websites sheet, immediate group move"
```

---

### Task 13: App — `EntryEditView` hero+card reskin, edit-only Delete, Websites entry point

**Files:**
- Modify: `MyPass/UI/EntryDetail/EntryEditView.swift`
- Modify: `MyPass/ContentView.swift`

**Interfaces:**
- Consumes: `KdbxEntry.standardFieldKeys`/`additionalFields` (Task 3), `WebsitesSheet` (Task 10), `UIShellMetrics.detailHeroLetterScale` (Task 6), `GroupTreeOperations.softDeleteEntry` (existing, `GroupTreeOperations.swift:172-181`)
- Produces: `EntryEditView` gains a new required `onDelete: () -> Void` closure parameter, changing its initializer signature — the one existing call site in `ContentView.swift` is updated in this same task.

There is no automated test for this step (SwiftUI layout/interaction, no test infra); verify manually per Step 5. `EntryEditSaveLogic` (the one piece of this view's logic that is unit-tested) is untouched by this task.

- [ ] **Step 1: Add `onDelete` and reuse the shared standard-keys/additionalFields API**

In `MyPass/UI/EntryDetail/EntryEditView.swift`, add the new stored property and initializer parameter (current lines 4-49):

```swift
struct EntryEditView: View {
    let existingEntry: KdbxEntry?
    let rootGroup: KdbxGroup
    let recycleBinGroupUUID: UUID?
    let defaultGroupID: UUID
    let onCancel: () -> Void
    let onSave: (KdbxEntry, UUID) -> Void
    let onDelete: () -> Void

    @State private var selectedGroupID: UUID
    @State private var showOTPField: Bool
    @State private var title: String = ""
    @State private var login: String = ""
    @State private var password: String = ""
    @State private var url: String = ""
    @State private var notes: String = ""
    @State private var otpauthInput: String = ""
    @State private var extraFields: [(key: String, value: String)] = []
    @State private var showPasswordGenerator = false
    @State private var isPasswordRevealed = false
    @State private var showWebsitesSheet = false

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
        _showOTPField = State(initialValue: existingEntry?.totpSecretBase32?.isEmpty == false)
        _title = State(initialValue: existingEntry?.title ?? "")
        _login = State(initialValue: existingEntry?.login ?? "")
        _password = State(initialValue: existingEntry?.password ?? "")
        _url = State(initialValue: existingEntry?.url ?? "")
        _notes = State(initialValue: existingEntry?.notes ?? "")
        _extraFields = State(initialValue: (existingEntry?.additionalFields ?? [])
            .map { (key: $0.key, value: $0.value) })
    }
```

- [ ] **Step 2: Reskin `body` with hero + fields card, keep the same Cancel/Save toolbar**

Replace the bare `Form` (current lines 51-119) with the hero + card frame, matching `EntryDetailView`'s `DetailFieldsCard` structure:

```swift
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

                TextField("Username", text: $login)
                Divider().overlay(Color.primary.opacity(0.08))

                HStack {
                    Group {
                        if isPasswordRevealed {
                            TextField("Password", text: $password)
                        } else {
                            SecureField("Password", text: $password)
                        }
                    }
                    Button {
                        isPasswordRevealed.toggle()
                    } label: {
                        Image(systemName: isPasswordRevealed ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(isPasswordRevealed ? "Hide password" : "Show password")
                    Button("Generate") { showPasswordGenerator = true }
                }
                Divider().overlay(Color.primary.opacity(0.08))

                HStack {
                    TextField("URL", text: $url)
                    if existingEntry != nil {
                        Button("Edit Websites…") { showWebsitesSheet = true }
                    }
                }
                Divider().overlay(Color.primary.opacity(0.08))

                TextField("Notes", text: $notes, axis: .vertical)
                    .lineLimit(3...8)
                    .frame(minHeight: 80)
                Divider().overlay(Color.primary.opacity(0.08))

                if showOTPField {
                    TextField("otpauth:// or secret", text: $otpauthInput)
                } else {
                    Button("+ Add one-time password") { showOTPField = true }
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
    .navigationTitle(existingEntry == nil ? "New Entry" : "Edit Entry")
    .toolbar {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", action: onCancel)
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Save", action: save)
                .keyboardShortcut(.return, modifiers: .command)
        }
    }
    .sheet(isPresented: $showPasswordGenerator) {
        PasswordGeneratorView { generated in
            password = generated
            showPasswordGenerator = false
        }
    }
    .sheet(isPresented: $showWebsitesSheet) {
        if let existingEntry {
            WebsitesSheet(
                entryID: existingEntry.uuid,
                entryTitle: title,
                initialURLs: existingEntry.urls,
                onDone: { newURLs in
                    url = newURLs.first ?? ""
                    showWebsitesSheet = false
                },
                onCancel: { showWebsitesSheet = false }
            )
        }
    }
}
```

Add a small private card wrapper matching `EntryDetailView`'s `DetailFieldsCard` chrome (kept as a separate type here since `EntryEditView` and `EntryDetailView` are different files and `DetailFieldsCard` is `private` to `EntryDetailView.swift`):

```swift
private struct EntryEditFieldsCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 12) {
            content()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: UIShellMetrics.cardCornerRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: UIShellMetrics.cardCornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
        .frame(maxWidth: UIShellMetrics.cardMaxWidth)
    }
}
```

**Note for the implementer:** the `WebsitesSheet`'s `onDone` closure reassigns the local `url` `@State` to the new primary URL. This is required, not optional — `WebsitesSheet.done()` persists directly via `vaultSession.mutate` (bypassing this view's own `save()`), so if `url` is left stale and the user subsequently taps this view's own **Save**, `save()` would silently overwrite the just-changed website back to the pre-sheet value.

- [ ] **Step 3: Update `save()` to use the shared `additionalFields`/`standardFieldKeys` API**

Replace the inline `standardKeys` filtering in `save()` (current lines 121-149):

```swift
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
    entry.title = EntryEditSaveLogic.resolvedTitle(draftTitle: title, url: url)
    entry.login = login
    entry.password = password
    entry.url = url
    entry.notes = notes
    entry.lastModificationTime = now
    entry.lastAccessTime = now
    EntryEditSaveLogic.applyOTP(to: &entry, otpauthInput: otpauthInput)

    entry.fields.removeAll { !KdbxEntry.standardFieldKeys.contains($0.key) }
    for field in extraFields where !field.key.isEmpty {
        entry.fields.append(KdbxField(key: field.key, value: field.value, isProtected: false))
    }

    onSave(entry, selectedGroupID)
}
```

(Only the standard-keys filter line changed — everything else in `save()` is unchanged from the current file. `entry.url = url` still only ever sets the primary URL, matching existing behavior; extra URLs live only in `entry.stringArrays`, untouched by `save()` since `WebsitesSheet` already persisted them directly.)

- [ ] **Step 4: Wire `onDelete` at the one call site in `ContentView.swift`**

In `MyPass/ContentView.swift`, find the `EntryEditView(...)` construction(s) inside `entryEdit(...)` (current lines ~86-100 area of `DetailColumnView`) and add the `onDelete` argument, calling the same soft-delete + clear-selection behavior `EntryDetailView`'s old browse Delete button used to perform:

```swift
EntryEditView(
    existingEntry: existingEntry,
    rootGroup: rootGroup,
    recycleBinGroupUUID: recycleBinGroupUUID,
    defaultGroupID: defaultGroupID,
    onCancel: { navigationState.presentBrowse() },
    onSave: { saved, groupID in
        // existing onSave body, unchanged
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
```

**Note for the implementer:** match this exactly against the existing `onCancel`/`onSave` closures already present at this call site in `ContentView.swift` — only add the new `onDelete:` argument; do not change `onCancel`/`onSave`. If `ContentView.swift` constructs `EntryEditView` more than once (e.g. separately for `.edit`, `.create`, `.createFromProposal` per `DetailPresentation`), every call site needs an `onDelete` argument — for the `.create`/`.createFromProposal` cases (where `existingEntry` is `nil`), pass `onDelete: {}` (a no-op), since the Delete button in `EntryEditView`'s body is already gated behind `if existingEntry != nil` and will never be visible/tappable in create mode.

- [ ] **Step 5: Manual verification**

Build and run the app.
- Open Edit on an existing entry: confirm the form now shows the same hero avatar + rounded field card as browse, not a bare `Form`.
- Confirm Cancel/Save toolbar buttons still work exactly as before (⌘-Return still saves).
- Confirm a red-text "Delete" button appears below the card, only in edit, only for an existing entry (not when creating a new entry).
- Tap Delete: confirm the entry is soft-deleted to Recycle Bin and the view returns to an empty/browse state, matching the old browse-Delete behavior.
- Click "Edit Websites…" next to the URL field, add a second URL, tap Done: confirm the change is visible immediately (check browse afterward) even before tapping this view's own Save. Then edit the Title and tap this view's Save: confirm the website change from the sheet is **not** reverted.
- Create a new entry (not editing an existing one): confirm no Delete button and no "Edit Websites…" button appear.

- [ ] **Step 6: Commit**

```bash
git add MyPass/UI/EntryDetail/EntryEditView.swift MyPass/ContentView.swift
git commit -m "feat(mypass): reskin edit view with hero+card frame, move Delete to edit, add Websites entry point"
```

---

## Self-Review

**Spec coverage check** (against `docs/superpowers/specs/2026-07-28-password-detail-form-design.md`):
- Shared hero + fields card frame for browse/edit → Tasks 11, 13.
- Hero letter sizing (~55-60%) → Task 6.
- Browse row order incl. domain-only Website → Task 11.
- Live TOTP ring (16-18 pt, green, 1 s refresh) → Tasks 8, 11.
- Primary-click copy behavior unchanged for Username/Password/Verification Code → untouched (only additive `.contextMenu`/`.popover` modifiers layered on in Task 12; no existing `Button` tap-action code was changed).
- Context menus (Copy + Show Large Type; Website Open/Copy/Change; Group submenu w/ immediate move) → Task 12.
- Delete removed from browse, red-text Delete in edit only, security stub removed → Tasks 11, 13.
- Multi-URL `KP2A_URL` StringArray storage, `entry.urls` API, codec round-trip, extension matcher over all URLs, hidden from Additional Fields → Tasks 1-4 (StringArray never touches `fields`, so it's automatically excluded from `additionalFields` by construction — documented in Task 3).
- Websites sheet (title, autofill copy, +/-, Done persists immediately via `vaultSession.mutate`, Cancel discards) → Task 10, wired in Tasks 12 (browse) and 13 (edit).
- Unit test coverage for StringArray codec, `urls` convenience, domain helper, matcher-all-URLs → Tasks 1, 2, 3, 4, 7.

**Explicit out-of-scope items confirmed untouched by any task:** security audit UI, Share toolbar, inline browse/edit merge, menu bar panel, Public Suffix List, localization catalogs, list-row inline TOTP/favicon — none of the 13 tasks above modify any file related to these areas.

**Placeholder scan:** no task contains "TBD"/"handle appropriately"/"similar to Task N" — every step shows the literal code to write or the literal manual-verification checklist to run.

**Type consistency check:** `KdbxStringArray` (Task 1) → consumed identically in Task 2 (`KdbxStringArray(key:values:)`), Task 3 (`stringArrays.first(where:)`, `.append(KdbxStringArray(...))`). `KdbxEntry.urls` (Task 3) → consumed identically in Task 4 (`entry.urls.contains`), Task 10 (`location.group.entries[location.index].urls = trimmed`), Task 11 (`entry.urls.isEmpty`), Task 13 (`existingEntry.urls`). `KdbxEntry.additionalFields`/`standardFieldKeys` (Task 3) → consumed identically in Task 11 (`entry.additionalFields`) and Task 13 (`existingEntry?.additionalFields`, `KdbxEntry.standardFieldKeys`). `GroupTreeOperations.selectableGroups(in:excludingRecycleBin:)` (Task 5) → consumed identically in Task 12. `TOTPCountdownRingView(period:now:diameter:)` (Task 8) → consumed identically in Task 11 (`TOTPCountdownRingView(period: 30, now: now)`, relying on the `diameter: CGFloat = 17` default). `WebsitesSheet(entryID:entryTitle:initialURLs:onDone:onCancel:)` (Task 10) → consumed identically (same 5 labels) in Task 12 and Task 13. `EntryEditView`'s new `onDelete: () -> Void` parameter (Task 13) → its one call site in `ContentView.swift` is updated in the same task, so the build never breaks mid-plan.

No gaps found; no fixes needed beyond what's already reflected above.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-07-28-password-detail-form.md`. Two execution options:

1. **Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
