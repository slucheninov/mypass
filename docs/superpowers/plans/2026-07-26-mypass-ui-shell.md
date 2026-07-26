# MyPass UI Shell (Apple Passwords–inspired) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restyle the existing three-column MyPass macOS shell (sidebar, entry list, detail), plus Unlock and Settings, to match the approved Apple Passwords–inspired visual design — Wave 1 visual chrome and layout only, with explicit UI stubs where backing logic is deferred.

**Architecture:** Keep `NavigationSplitView` + `NavigationState` + `VaultSession` unchanged in behavior. Introduce a small `MyPass/UI/Shell/` module for shared metrics, letter avatars, and smart-category stub metadata. Restyle the five existing views in place rather than adding parallel UI modules. Smart category selection updates highlight state only; entry list data path remains group + search.

**Tech Stack:** SwiftUI, macOS 14.0+, XCTest, XcodeGen (`project.yml`), existing MyPass NavigationSplitView / VaultSession / NavigationState

## Global Constraints

- English UI strings only (Phase 7 localization is separate)
- Visual shell only — do not wire smart category filters, live counts, favorites storage, density behavior, menu bar redesign, favicon fetch, security audit logic
- Preserve vault unlock/lock, group selection, entry CRUD, search, sync, Chrome extension settings
- Prefer restyling existing views over parallel UI modules
- Prefer SwiftUI semantic colors over hard-coded hex
- Tests via `scripts/test.sh` / `xcodebuild`; no SwiftUI snapshot tests required
- Spec reference: `docs/superpowers/specs/2026-07-26-mypass-ui-shell-design.md`
- `project.yml` glob-includes all files under `MyPass/` and `MyPassTests/` (`sources: - path: MyPass` / `MyPassTests`) — **no `project.yml` change** required for new Swift files in those folders

---

## File structure (created/modified by this plan)

```
MyPass/UI/Shell/
  UIShellMetrics.swift          (NEW — shared sizes, radii, layout constants)
  LetterAvatar.swift            (NEW — letter + color helpers + LetterAvatarView)
  SmartCategory.swift           (NEW — stub category enum + accent colors + placeholder counts)

MyPass/State/
  NavigationState.swift         (MODIFY — add selectedSmartCategory)

MyPass/UI/Sidebar/
  GroupSidebarView.swift        (MODIFY — Categories stubs + Groups + Recycle Bin layout)

MyPass/UI/EntryList/
  EntryListView.swift           (MODIFY — letter avatar rows, selection chrome, header title)

MyPass/UI/EntryDetail/
  EntryDetailView.swift         (MODIFY — empty state; filled card; Share/security/TOTP stubs)

MyPass/UI/Unlock/
  UnlockView.swift              (MODIFY — airy centered layout)

MyPass/UI/Settings/
  SettingsView.swift            (MODIFY — helper subtext under each section; no density control)

MyPassTests/
  LetterAvatarTests.swift       (NEW)
  SmartCategoryTests.swift      (NEW)
```

---

### Task 1: UIShellMetrics + LetterAvatar + LetterAvatarTests (TDD)

**Files:**
- Create: `MyPass/UI/Shell/UIShellMetrics.swift`
- Create: `MyPass/UI/Shell/LetterAvatar.swift`
- Create: `MyPassTests/LetterAvatarTests.swift`

**Interfaces:**
- Consumes: SwiftUI, AppKit (`NSColor` for test color comparison)
- Produces:
  - `enum UIShellMetrics` with layout constants (see Step 3)
  - `enum LetterAvatar` with `static func letter(from title: String) -> String`, `static func color(for title: String) -> Color`
  - `struct LetterAvatarView: View` with `init(title: String, size: CGFloat, cornerRadius: CGFloat)`

- [ ] **Step 1: Write the failing tests**

Create `MyPassTests/LetterAvatarTests.swift`:

```swift
import XCTest
import SwiftUI
import AppKit
@testable import MyPass

final class LetterAvatarTests: XCTestCase {
    func testLetterFromNonEmptyTitle() {
        XCTAssertEqual(LetterAvatar.letter(from: "GitHub"), "G")
        XCTAssertEqual(LetterAvatar.letter(from: "amazon"), "A")
    }

    func testLetterFromEmptyOrWhitespaceTitle() {
        XCTAssertEqual(LetterAvatar.letter(from: ""), "?")
        XCTAssertEqual(LetterAvatar.letter(from: "   "), "?")
    }

    func testColorIsDeterministicForSameTitle() {
        let first = rgbaComponents(LetterAvatar.color(for: "Example Service"))
        let second = rgbaComponents(LetterAvatar.color(for: "Example Service"))
        XCTAssertEqual(first, second)
    }

    func testColorDiffersForDifferentTitlesUsually() {
        let a = rgbaComponents(LetterAvatar.color(for: "Alpha"))
        let b = rgbaComponents(LetterAvatar.color(for: "Beta"))
        // Not guaranteed for every pair, but these hash to different palette slots.
        XCTAssertNotEqual(a, b)
    }

    private func rgbaComponents(_ color: Color) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        let ns = NSColor(color).usingColorSpace(.sRGB)!
        return (ns.redComponent, ns.greenComponent, ns.blueComponent, ns.alphaComponent)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/generate.sh && xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/LetterAvatarTests 2>&1 | tail -20`

Expected: FAIL — `LetterAvatar` / `LetterAvatarTests` symbol not found

- [ ] **Step 3: Write minimal implementation**

Create `MyPass/UI/Shell/UIShellMetrics.swift`:

```swift
import SwiftUI

enum UIShellMetrics {
    static let listIconSize: CGFloat = 36
    static let detailHeroIconSize: CGFloat = 72
    static let listIconCornerRadius: CGFloat = 8
    static let detailHeroIconCornerRadius: CGFloat = 16
    static let cardCornerRadius: CGFloat = 12
    static let cardMaxWidth: CGFloat = 420
    static let sidebarPreferredWidth: CGFloat = 200
    static let listColumnMinWidth: CGFloat = 260
    static let selectionAccentBarWidth: CGFloat = 3
    static let emptyStateIconSize: CGFloat = 64

    /// Detail column backdrop — semantic so light/dark stay readable.
    static var detailColumnBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }
}
```

Create `MyPass/UI/Shell/LetterAvatar.swift`:

```swift
import SwiftUI

enum LetterAvatar {
    private static let palette: [Color] = [
        .blue, .green, .orange, .purple, .pink, .teal, .indigo, .mint, .cyan, .brown
    ]

    static func letter(from title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased()
    }

    static func color(for title: String) -> Color {
        let hash = title.utf8.reduce(0) { ($0 &+ Int($1)) &* 31 }
        let index = abs(hash) % palette.count
        return palette[index]
    }
}

struct LetterAvatarView: View {
    let title: String
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(LetterAvatar.color(for: title))
            Text(LetterAvatar.letter(from: title))
                .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityLabel(Text("Icon for \(title.isEmpty ? "untitled entry" : title)"))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/LetterAvatarTests 2>&1 | tail -20`

Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add MyPass/UI/Shell/UIShellMetrics.swift MyPass/UI/Shell/LetterAvatar.swift MyPassTests/LetterAvatarTests.swift
git commit -m "feat(ui): add shell metrics and letter avatar helpers"
```

---

### Task 2: SmartCategory enum + SmartCategoryTests + NavigationState.selectedSmartCategory

**Files:**
- Create: `MyPass/UI/Shell/SmartCategory.swift`
- Create: `MyPassTests/SmartCategoryTests.swift`
- Modify: `MyPass/State/NavigationState.swift`

**Interfaces:**
- Consumes: `UIShellMetrics` (none yet), SwiftUI `Color`
- Produces:
  - `enum SmartCategory: String, CaseIterable, Identifiable, Hashable` with cases `all`, `favorites`, `codes`, `security`, `deleted`; properties `id`, `title`, `placeholderCount`, `accentColor`
  - `NavigationState.selectedSmartCategory: SmartCategory` (default `.all`)

- [ ] **Step 1: Write the failing tests**

Create `MyPassTests/SmartCategoryTests.swift`:

```swift
import XCTest
@testable import MyPass

final class SmartCategoryTests: XCTestCase {
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

    func testPlaceholderCounts() {
        XCTAssertEqual(SmartCategory.all.placeholderCount, "58")
        XCTAssertEqual(SmartCategory.favorites.placeholderCount, "0")
        XCTAssertEqual(SmartCategory.codes.placeholderCount, "15")
        XCTAssertEqual(SmartCategory.security.placeholderCount, "—")
        XCTAssertEqual(SmartCategory.deleted.placeholderCount, "0")
    }

    func testIdentifiableUsesRawValue() {
        for category in SmartCategory.allCases {
            XCTAssertEqual(category.id, category.rawValue)
        }
    }
}
```

Add to `MyPassTests/NavigationStateSearchTests.swift` **or** append to `SmartCategoryTests.swift`:

```swift
    func testNavigationStateDefaultsSelectedSmartCategoryToAll() {
        let state = NavigationState()
        XCTAssertEqual(state.selectedSmartCategory, .all)
    }
```

(If `NavigationStateSearchTests.swift` exists, prefer adding the navigation test there instead of duplicating a new file.)

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/SmartCategoryTests 2>&1 | tail -20`

Expected: FAIL — `SmartCategory` not found; `NavigationState` has no `selectedSmartCategory`

- [ ] **Step 3: Write minimal implementation**

Create `MyPass/UI/Shell/SmartCategory.swift`:

```swift
import SwiftUI

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

    /// Wave 1: static placeholder only — not computed from vault data.
    var placeholderCount: String {
        switch self {
        case .all: return "58"
        case .favorites: return "0"
        case .codes: return "15"
        case .security: return "—"
        case .deleted: return "0"
        }
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

Modify `MyPass/State/NavigationState.swift` — add after `searchText`:

```swift
    @Published var selectedSmartCategory: SmartCategory = .all
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -only-testing:MyPassTests/SmartCategoryTests 2>&1 | tail -20`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add MyPass/UI/Shell/SmartCategory.swift MyPass/State/NavigationState.swift MyPassTests/SmartCategoryTests.swift
git commit -m "feat(ui): add smart category stubs and navigation state"
```

---

### Task 3: GroupSidebarView — Categories stubs section (highlight only)

**Files:**
- Modify: `MyPass/UI/Sidebar/GroupSidebarView.swift`

**Interfaces:**
- Consumes: `SmartCategory`, `NavigationState.selectedSmartCategory`, `NavigationState.selectedGroupID`, existing `KdbxGroup` tree + recycle bin UUID
- Produces: `SmartCategorySidebarRow` (private struct in same file) rendering dot + label + count + selection pill; category tap sets `selectedSmartCategory` only

- [ ] **Step 1: Add private sidebar row helper and section header**

At the bottom of `GroupSidebarView.swift`, add:

```swift
private struct SidebarSectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}

private struct SmartCategorySidebarRow: View {
    let category: SmartCategory
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(category.accentColor)
                .frame(width: 8, height: 8)
            Text(category.title)
                .foregroundStyle(.primary)
            Spacer(minLength: 4)
            Text(category.placeholderCount)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? category.accentColor.opacity(0.18) : Color.clear)
        )
        .contentShape(Rectangle())
    }
}
```

- [ ] **Step 2: Restructure `body` to Categories → Groups → Recycle Bin**

Replace the current `List(selection:)` body with:

```swift
    var body: some View {
        List(selection: $navigationState.selectedGroupID) {
            Section {
                ForEach(SmartCategory.allCases) { category in
                    SmartCategorySidebarRow(
                        category: category,
                        isSelected: navigationState.selectedSmartCategory == category
                    )
                    .onTapGesture {
                        // Wave 1: visual selection only — entry list filtering is unchanged.
                        navigationState.selectedSmartCategory = category
                    }
                }
            } header: {
                SidebarSectionHeader(title: "Categories")
            }

            Section {
                OutlineGroup([rootGroup], children: \.subgroupsForOutline) { group in
                    Text(group.name)
                        .tag(group.uuid)
                        .contextMenu {
                            Button("New Subgroup") {
                                vaultSession.mutate { _ in
                                    GroupTreeOperations.addSubgroup(named: "New Group", to: group)
                                }
                            }
                            if group.uuid != rootGroup.uuid {
                                Button("Delete Group", role: .destructive) {
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
            } header: {
                SidebarSectionHeader(title: "Groups")
            }

            Section {
                if let uuid = recycleBinGroupUUID, let bin = rootGroup.subgroups.first(where: { $0.uuid == uuid }) {
                    Text(GroupTreeOperations.recycleBinGroupName)
                        .tag(bin.uuid)
                } else {
                    Text(GroupTreeOperations.recycleBinGroupName)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: UIShellMetrics.sidebarPreferredWidth)
    }
```

- [ ] **Step 3: Build to verify compile**

Run: `./scripts/build.sh 2>&1 | tail -20`

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Manual smoke — categories highlight, groups still select, recycle bin pinned**

Launch: `./scripts/run.sh` (or open built app). Confirm:
- Tapping Favorites/Codes/Security/Deleted changes pill highlight only
- Group tree selection still drives entry list
- Recycle Bin row remains at bottom

- [ ] **Step 5: Commit**

```bash
git add MyPass/UI/Sidebar/GroupSidebarView.swift
git commit -m "feat(ui): add smart category stub section to sidebar"
```

---

### Task 4: EntryListView — letter avatar rows and selection chrome

**Files:**
- Modify: `MyPass/UI/EntryList/EntryListView.swift`

**Interfaces:**
- Consumes: `LetterAvatarView`, `UIShellMetrics`, `NavigationState.selectedSmartCategory`, `NavigationState.selectedEntryID`, `NavigationState.searchText`, `KdbxEntry.title` / `login`
- Produces: `EntryListRow` private view; `headerTitle` computed property; restyled list rows without inline TOTP

- [ ] **Step 1: Add private row view and header title helper**

Add to `EntryListView.swift`:

```swift
    private var headerTitle: String {
        if navigationState.selectedSmartCategory != .all {
            return navigationState.selectedSmartCategory.title
        }
        return currentGroup.name
    }

    private func displayTitle(for entry: KdbxEntry) -> String {
        entry.title.isEmpty ? "(untitled)" : entry.title
    }
```

Add private struct at file bottom:

```swift
private struct EntryListRow: View {
    let title: String
    let subtitle: String
    let isSelected: Bool

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
        .listRowBackground(rowBackground)
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isSelected {
            HStack(spacing: 0) {
                Color.accentColor
                    .frame(width: UIShellMetrics.selectionAccentBarWidth)
                Color.accentColor.opacity(0.12)
            }
        } else {
            Color.clear
        }
    }
}
```

- [ ] **Step 2: Replace list row content and add navigation title**

Replace the `List(displayedEntries, selection:)` row closure with:

```swift
        List(displayedEntries, selection: $navigationState.selectedEntryID) { entry in
            EntryListRow(
                title: displayTitle(for: entry),
                subtitle: entry.login,
                isSelected: navigationState.selectedEntryID == entry.uuid
            )
            .tag(entry.uuid)
            .draggable(entry.uuid.uuidString)
        }
        .navigationTitle(headerTitle)
        .frame(minWidth: UIShellMetrics.listColumnMinWidth)
```

Keep existing `.searchable`, `.toolbar`, and `.sheet` blocks unchanged.

- [ ] **Step 3: Build**

Run: `./scripts/build.sh 2>&1 | tail -20`

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Manual smoke**

Confirm list rows show 36×36 letter avatars, blue selection bar + tint, no trailing TOTP slot, header switches between group name and smart category title.

- [ ] **Step 5: Commit**

```bash
git add MyPass/UI/EntryList/EntryListView.swift
git commit -m "feat(ui): restyle entry list rows with letter avatars"
```

---

### Task 5: EntryDetailView — empty state

**Files:**
- Modify: `MyPass/UI/EntryDetail/EntryDetailView.swift`

**Interfaces:**
- Consumes: `UIShellMetrics.detailColumnBackground`, `UIShellMetrics.emptyStateIconSize`
- Produces: `DetailEmptyStateView` private view; detail column uses semantic background when no entry selected

- [ ] **Step 1: Add empty state view**

Add at bottom of `EntryDetailView.swift`:

```swift
private struct DetailEmptyStateView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.key")
                .font(.system(size: UIShellMetrics.emptyStateIconSize))
                .foregroundStyle(.secondary.opacity(0.35))
            Text("Nothing Selected")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Select an entry from the list")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(UIShellMetrics.detailColumnBackground)
    }
}
```

- [ ] **Step 2: Replace the `else` branch**

Change:

```swift
        } else {
            Text("Select an entry")
        }
```

to:

```swift
        } else {
            DetailEmptyStateView()
        }
```

- [ ] **Step 3: Build**

Run: `./scripts/build.sh 2>&1 | tail -20`

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add MyPass/UI/EntryDetail/EntryDetailView.swift
git commit -m "feat(ui): add entry detail empty state"
```

---

### Task 6: EntryDetailView — filled card layout + Share/security/TOTP stubs

**Files:**
- Modify: `MyPass/UI/EntryDetail/EntryDetailView.swift`

**Interfaces:**
- Consumes: `LetterAvatarView`, `UIShellMetrics`, existing `copy(_:)`, `TOTPCode.currentCode`, `entry.totpSecretBase32`, `entry.lastModificationTime`, history/edit sheets, delete/restore mutations
- Produces:
  - Toolbar: disabled Share, wired Edit
  - Hero block (72×72 avatar + 22 pt bold title)
  - `DetailFieldsCard` with Username, Password, Website, Modified, Notes, TOTP row
  - Static TOTP ring chrome (non-animated `Circle().stroke`)
  - `View History` text button
  - Dashed `SecurityWarningStubView`
  - Delete/Restore buttons preserved below stubs

- [ ] **Step 1: Add supporting private views**

Add to `EntryDetailView.swift` (below empty state struct):

```swift
private struct DetailFieldDivider: View {
    var body: some View {
        Divider().overlay(Color.primary.opacity(0.08))
    }
}

private struct DetailFieldRow: View {
    let label: String
    let value: String
    var isLink: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            if isLink, let url = URL(string: value), !value.isEmpty {
                Link(value, destination: url)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                Text(value)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .font(.body)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private struct DetailFieldsCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
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

private struct TOTPRingChrome: View {
    var body: some View {
        Circle()
            .stroke(Color.secondary.opacity(0.35), lineWidth: 2)
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)
    }
}

private struct SecurityWarningStubView: View {
    var body: some View {
        Text("Security warning (coming later)")
            .font(.body.italic())
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.vertical, 20)
            .padding(.horizontal, 16)
            .frame(maxWidth: UIShellMetrics.cardMaxWidth)
            .background(
                RoundedRectangle(cornerRadius: UIShellMetrics.cardCornerRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: UIShellMetrics.cardCornerRadius, style: .continuous)
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                    .foregroundStyle(Color.secondary.opacity(0.5))
            )
            .accessibilityLabel(Text("Security warning placeholder"))
    }
}
```

- [ ] **Step 2: Replace filled-state `Form` with card layout**

Replace the `if let entry = currentEntry { Form { ... } }` block body (keep sheets, timer, onReceive) with:

```swift
        if let entry = currentEntry {
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 12) {
                        LetterAvatarView(
                            title: entry.title.isEmpty ? "(untitled)" : entry.title,
                            size: UIShellMetrics.detailHeroIconSize,
                            cornerRadius: UIShellMetrics.detailHeroIconCornerRadius
                        )
                        Text(entry.title.isEmpty ? "(untitled)" : entry.title)
                            .font(.system(size: 22, weight: .bold))
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 24)

                    DetailFieldsCard {
                        DetailFieldRow(label: "Username", value: entry.login)

                        DetailFieldDivider()

                        HStack(alignment: .center, spacing: 12) {
                            Text("Password")
                                .foregroundStyle(.secondary)
                                .frame(width: 100, alignment: .leading)
                            Text(isPasswordRevealed ? entry.password : String(repeating: "•", count: max(entry.password.count, 8)))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            Button(isPasswordRevealed ? "Hide" : "Show") { isPasswordRevealed.toggle() }
                                .buttonStyle(.borderless)
                            Button("Copy", systemImage: "doc.on.doc") { copy(entry.password) }
                                .buttonStyle(.borderless)
                        }
                        .font(.body)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)

                        if !entry.url.isEmpty {
                            DetailFieldDivider()
                            DetailFieldRow(label: "Website", value: entry.url, isLink: true)
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

                        if let secret = entry.totpSecretBase32 {
                            DetailFieldDivider()
                            let code = TOTPCode.currentCode(secretBase32: secret, digits: 6, period: 30, algorithm: .sha1, now: now) ?? "------"
                            HStack(alignment: .center, spacing: 12) {
                                Text("Verification Code")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 100, alignment: .leading)
                                Spacer(minLength: 0)
                                Text(code)
                                    .font(.system(.body, design: .monospaced))
                                TOTPRingChrome()
                                Button("Copy", systemImage: "doc.on.doc") { copy(code) }
                                    .buttonStyle(.borderless)
                            }
                            .font(.body)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                        }
                    }

                    Button("View History") { showHistory = true }
                        .buttonStyle(.plain)
                        .foregroundStyle(.accent)

                    SecurityWarningStubView()

                    HStack(spacing: 16) {
                        if isInRecycleBin(entry) {
                            Button("Restore") {
                                vaultSession.mutate { database in
                                    GroupTreeOperations.restoreEntry(withID: entry.uuid, to: database.rootGroup.uuid, in: database.rootGroup)
                                }
                                navigationState.selectedEntryID = nil
                            }
                        } else {
                            Button("Delete", role: .destructive) {
                                vaultSession.mutate { database in
                                    GroupTreeOperations.softDeleteEntry(withID: entry.uuid, in: database.rootGroup, deletedObjects: &database.deletedObjects, recycleBinGroupUUID: &database.recycleBinGroupUUID)
                                }
                                navigationState.selectedEntryID = nil
                            }
                        }
                    }
                    .padding(.bottom, 24)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
            }
            .background(UIShellMetrics.detailColumnBackground)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Share", systemImage: "square.and.arrow.up") { }
                        .disabled(true)
                        .help("Share is not available yet")
                    Button("Edit", systemImage: "square.and.pencil") { showEdit = true }
                }
            }
            .onReceive(timer) { now = $0 }
            .sheet(isPresented: $showHistory) { /* unchanged */ }
            .sheet(isPresented: $showEdit) { /* unchanged */ }
        }
```

Re-copy the existing `.sheet` closures verbatim from the current file — do not drop history/edit handlers.

**Important:** Remove the old inline `Text("(\(Int(remaining))s)")` TOTP countdown label. Keep `Timer.publish` + `onReceive` so digits may still refresh; ring stays static (Wave 1 stub).

- [ ] **Step 3: Build**

Run: `./scripts/build.sh 2>&1 | tail -20`

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Manual smoke**

With a TOTP entry selected: verify static ring, no seconds label, copy works. Share button greyed out. Security dashed card visible. Edit opens existing sheet.

- [ ] **Step 5: Commit**

```bash
git add MyPass/UI/EntryDetail/EntryDetailView.swift
git commit -m "feat(ui): restyle entry detail card with wave-1 stubs"
```

---

### Task 7: UnlockView — airy centered layout

**Files:**
- Modify: `MyPass/UI/Unlock/UnlockView.swift`

**Interfaces:**
- Consumes: existing `attemptUnlock()`, `attemptBiometricUnlock()`, `hasStoredBiometricKey`, `password`, `errorMessage`
- Produces: restyled layout only — no new unlock logic

- [ ] **Step 1: Replace `body` with spec layout**

Replace `UnlockView.body` with:

```swift
    var body: some View {
        VStack(spacing: 20) {
            Text("MyPass")
                .font(.system(size: 28, weight: .semibold))

            Image(systemName: "key.fill")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

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
```

- [ ] **Step 2: Build**

Run: `./scripts/build.sh 2>&1 | tail -20`

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add MyPass/UI/Unlock/UnlockView.swift
git commit -m "feat(ui): restyle unlock screen layout"
```

---

### Task 8: SettingsView — helper subtext under sections

**Files:**
- Modify: `MyPass/UI/Settings/SettingsView.swift`

**Interfaces:**
- Consumes: all existing `@AppStorage` bindings and section controls (unchanged)
- Produces: `SettingsHelperText` private view; explanatory 11 pt subtext under Auto-Lock, Backups, Sync, Chrome Extension

**Note:** There is no separate Clipboard settings section today (clipboard auto-clear is hardcoded at 30 s in `EntryDetailView`). Do **not** add a new Clipboard control. Mention clipboard behavior in the Auto-Lock section helper only.

- [ ] **Step 1: Add helper text view**

Add at bottom of file:

```swift
private struct SettingsHelperText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
    }
}
```

- [ ] **Step 2: Wrap `Form` in `ScrollView` and add subtexts**

Replace the top-level `Form { ... }` wrapper with:

```swift
        ScrollView {
            Form {
                Section {
                    Stepper("Timeout: \(Int(autoLockTimeoutMinutes)) min", value: $autoLockTimeoutMinutes, in: 1...120)
                    SettingsHelperText(text: "Lock the vault automatically after inactivity so passwords stay protected when you step away.")
                    SettingsHelperText(text: "Copied usernames and passwords are cleared from the clipboard after 30 seconds when copied from an entry.")
                } header: {
                    Text("Auto-Lock")
                        .font(.system(size: 13, weight: .semibold))
                }

                Section {
                    Stepper("Keep last: \(backupCount)", value: $backupCount, in: 1...50)
                    SettingsHelperText(text: "Rotate local backup copies of your vault file so you can recover from a corrupted save.")
                } header: {
                    Text("Backups")
                        .font(.system(size: 13, weight: .semibold))
                }

                Section {
                    Picker("Backend", selection: $syncBackendRawValue) {
                        ForEach(SyncBackendOption.allCases) { option in
                            Text(option.rawValue).tag(option.rawValue)
                        }
                    }
                    switch selectedOption {
                    case .local: localFolderSection
                    case .iCloud: iCloudSection
                    case .sftp: sftpSection
                    }
                    Button("Sync Now") {
                        vaultSession.triggerBackgroundSync()
                        manualSyncStatusMessage = "Started…"
                    }
                    if let manualSyncStatusMessage {
                        Text(manualSyncStatusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    SettingsHelperText(text: "Choose where the encrypted vault is mirrored and run an immediate sync when you change devices or paths.")
                } header: {
                    Text("Sync")
                        .font(.system(size: 13, weight: .semibold))
                }

                Section {
                    chromeExtensionSection
                    SettingsHelperText(text: "Install the native messaging host so the Chrome extension can request matches and save proposals from the browser.")
                } header: {
                    Text("Chrome Extension")
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .formStyle(.grouped)
            .padding()
        }
        .frame(minWidth: 420)
```

Remove the old `.frame(width: 420)` on Form (replaced by `minWidth` on ScrollView). Keep all `.onAppear` / `.onChange` handlers on the ScrollView container.

- [ ] **Step 3: Build**

Run: `./scripts/build.sh 2>&1 | tail -20`

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add MyPass/UI/Settings/SettingsView.swift
git commit -m "feat(ui): add settings helper subtexts"
```

---

### Task 9: Manual acceptance pass + full test and build

**Files:**
- None (verification only)

**Interfaces:**
- Consumes: all Tasks 1–8 deliverables
- Produces: signed-off Wave 1 shell per spec acceptance criteria

- [ ] **Step 1: Run full unit test suite**

Run: `./scripts/test.sh 2>&1 | tail -40`

Expected: all `xcodebuild test`, MyPassKit, SyncKit, ExtensionBridgeKit tests PASS; ChromeExtension JS tests PASS if `node` installed

- [ ] **Step 2: Run release build**

Run: `./scripts/build.sh 2>&1 | tail -20`

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Manual acceptance checklist (Wave 1)**

Launch `./scripts/run.sh` and verify:

| # | Check | Pass? |
|---|-------|-------|
| 1 | Sidebar shows Categories (5 stubs) → divider → Groups tree → Recycle Bin bottom | |
| 2 | Category taps change highlight only; entry list content unchanged by category | |
| 3 | Group selection + search still filter entries | |
| 4 | List rows: 36×36 letter avatar, semibold title, 12 pt subtitle, blue selection bar | |
| 5 | List header title follows smart category (non-All) or group name | |
| 6 | No inline TOTP in list rows | |
| 7 | Detail empty state: centered icon, "Nothing Selected", hint copy | |
| 8 | Detail filled: hero 72×72 avatar, card ~420 pt, field rows, View History | |
| 9 | Share toolbar button disabled; Edit opens existing sheet | |
| 10 | TOTP row: code visible, static ring, no animated countdown fill; no `(Ns)` label | |
| 11 | Dashed security stub card, non-interactive | |
| 12 | Password show/copy, delete/restore, history unchanged | |
| 13 | Unlock: centered layout, helper text, Touch ID button when key stored | |
| 14 | Settings: scrolling grouped pane, helper subtext per section, no density control | |
| 15 | Vault unlock/lock, sync settings, Chrome extension settings still functional | |

- [ ] **Step 4: Dark Mode spot check**

Toggle System Settings → Appearance → Dark. Confirm sidebar, list selection, detail card, and unlock screen remain readable (no illegible hard-coded light grays on dark backgrounds).

- [ ] **Step 5: Final commit (if any fixups from checklist)**

Only if acceptance fixes were needed:

```bash
git add -A
git commit -m "fix(ui): wave-1 shell acceptance fixups"
```

---

## Self-review vs spec

| Spec requirement | Plan task | Notes |
|------------------|-----------|-------|
| Smart category stubs (All/Favorites/Codes/Security/Deleted) with static counts | Task 2, 3 | `placeholderCount` static; selection highlight only |
| Groups tree + Recycle Bin preserved | Task 3 | Existing `OutlineGroup` + bottom section |
| Entry list letter avatars 36×8 radius | Task 1, 4 | `LetterAvatarView` + `UIShellMetrics` |
| Selection chrome (blue bar + tint) | Task 4 | `EntryListRow.rowBackground` |
| No inline list TOTP | Task 4 | No TOTP in row layout |
| Detail empty state copy + illustration | Task 5 | `DetailEmptyStateView` |
| Detail hero 72×16, card 12 radius ~420 pt | Task 6 | `DetailFieldsCard` |
| Share disabled, Edit wired | Task 6 | Toolbar items |
| TOTP row static ring; digits may refresh | Task 6 | `TOTPRingChrome`; timer kept, seconds label removed |
| Security dashed stub | Task 6 | `SecurityWarningStubView` |
| View History wired | Task 6 | Existing sheet |
| Unlock airy layout + helper | Task 7 | Full body replacement |
| Settings helper subtext, no density | Task 8 | ScrollView + `SettingsHelperText`; clipboard note under Auto-Lock only |
| Preserve CRUD, search, sync, extension | All tasks | No changes to VaultSession / sync bindings |
| English strings only | Global Constraints | Literal English in views |
| Semantic colors / dark mode | Task 1, 6 | `NSColor` semantic backgrounds |
| No backlog features 1–10 logic | Global Constraints | Comments document no-op filters |
| `project.yml` inclusion | File structure | Directory glob — no change |

**Placeholder scan:** No TBD/TODO/similar-task references in task steps.

**Type consistency:** `SmartCategory`, `LetterAvatar`, `UIShellMetrics`, and `NavigationState.selectedSmartCategory` names match across Tasks 1–8.

---

**Plan complete.** Saved to `docs/superpowers/plans/2026-07-26-mypass-ui-shell.md`.

**Execution options:**

1. **Subagent-Driven (recommended)** — dispatch a fresh subagent per task with two-stage review between tasks.
2. **Inline Execution** — run tasks sequentially in one session using `executing-plans` with checkpoints after Tasks 3, 6, and 9.
