# Entry Templates: Login / Card / Notes

**Status:** Approved (design phase complete, pending implementation plan)
**Date:** 2026-07-29

## Summary

Currently, clicking "+" in the entry list always creates a Login entry — the only entry "type" MyPass supports, and only informally (the underlying `KdbxEntry` model has no type discriminator; every semantic field is a naming convention on a generic `[KdbxField]` array).

This spec adds two new entry templates — **Card** (credit/debit card storage) and **Notes** (markdown-capable secure text) — selectable from a new "+" menu, alongside the existing Login template. Card and Notes entries are surfaced through new virtual smart-category filters ("Cards", "Notes") in the sidebar, mirroring the existing Favorites/Codes/Security filters — no real KDBX group/folder is created automatically.

## Goals

- Clicking "+" shows a menu: Login / Card / Notes (reusing the existing `Menu(...)` toolbar pattern already used for "Import").
- Login behavior is unchanged.
- Card template: stores card number, cardholder name, expiry date, CVV — sensitive fields masked like the existing Password field.
- Notes template: a markdown-capable secure text note, with a formatting toolbar (B, I, U, H1, H2, H3, HR, inline code, code block).
- Card and Notes entries each get their own virtual smart-category filter in the sidebar ("Cards", "Notes"), computed the same way `.favorites`/`.codes` are today — not a real folder/group.
- Full backward compatibility: every entry in every existing vault has no `MyPass.EntryType` field and is therefore correctly treated as Login by default. No migration step needed.

## Non-goals (explicitly out of scope)

- CSV import stays Login-only.
- Chrome extension autofill/save bridge (`ExtensionBridgeKit`) stays Login-only; Card/Notes are not exposed to it.
- No "convert entry type" action (e.g. turning a Login into a Card) — not a real-world need.
- No card-brand detection or Luhn validation on the card number — display-only input formatting (grouping digits), not a validator.
- No rich WYSIWYG editing for Notes — the toolbar inserts raw markdown text into a plain `TextEditor`; there is no live "typing bold text renders bold" experience.
- No new markdown dependency — rendering uses Swift's built-in `AttributedString(markdown:)` only (see "Known limitation" under Notes below).

## 1. Data model — entry type discriminator

No new storage layer is needed: KDBX already allows arbitrary custom string fields on any entry, and the entire vault is a single encrypted KDBX4 XML blob with no schema enforcement (`Packages/MyPassKit/Sources/MyPassKit/Model/KdbxEntry.swift`, `Packages/MyPassKit/Sources/MyPassKit/Format/KdbxXmlCoder.swift`).

- Add a computed `entryType: EntryType` property to `KdbxEntry` (in `MyPass/Models/KdbxEntry+Convenience.swift`, alongside the existing `title`/`login`/`password`/`isFavorite` computed properties), backed by a new field key **`MyPass.EntryType`** with string values `"Card"` / `"Notes"`.
- **Absent field → `EntryType.login`** (the default). This is what makes every entry in every existing vault automatically and correctly a Login entry — zero migration required.
- Add `MyPass.EntryType` to `standardFieldKeys` (`KdbxEntry+Convenience.swift`) so it is never rendered as a free-form "additional field" row in the edit/detail UI.
- New template-specific field keys, following the existing `Password`/`otp` convention for protection:
  - **Card**: `CardNumber` (protected), `CardholderName` (not protected), `ExpiryDate` (not protected, free-text `MM/YY`, no date-math), `CVV` (protected)
  - **Notes**: `NotesBody` (not protected) — the markdown source text. A distinct key from the existing `Notes` field, because Login's `Notes` is a secondary/sibling field, while for a Notes entry this text *is* the entry's primary content — conflating the two would be semantically confusing.
- Other KDBX-aware clients (KeePass, KeePassXC, etc.) opening a vault containing these new fields will see them as ordinary custom fields — no corruption, graceful degradation, full interop preserved.

## 2. "+" menu & entry creation flow

- `MyPass/UI/EntryList/EntryListView.swift` (currently lines ~73-84): replace the plain `Button("Add", systemImage: "plus")` with a `Menu`, mirroring the existing `Menu("Import", systemImage: "square.and.arrow.down") { ... }` right next to it in the same toolbar:

  ```swift
  Menu("Add", systemImage: "plus") {
      Button("Login") { presentCreate(.login) }
      Button("Card") { presentCreate(.card) }
      Button("Notes") { presentCreate(.notes) }
  }
  ```

- `NavigationState.presentCreate(defaultGroupID:)` (`MyPass/State/NavigationState.swift`) gains an `entryType: EntryType` parameter, defaulting to `.login` so any other existing call sites keep compiling unchanged. The `DetailPresentation.create` enum case carries the chosen `entryType` alongside `defaultGroupID`.
- `ContentView`'s `entryEdit(existingID:defaultGroupID:proposal:)` routing helper (`ContentView.swift:66-117`) branches on the entry type — the presentation's chosen type when creating, or the existing entry's `entryType` when editing — to instantiate the correct view: `EntryEditView` (Login, unchanged), `CardEditView`, or `NotesEditView`.
- Default group/folder selection logic (`GroupTreeOperations.clampedDefaultGroupID`) is unchanged for all three templates — the new entry lands in whichever group is currently selected in the sidebar, exactly like Login does today. The "separate category" requirement from the original request is satisfied entirely by the virtual smart-category filters in section 5, not by any change to group placement.
- Editing an existing entry automatically opens the matching view based on its stored `entryType` — there is no user-facing "change entry type" action.

## 3. Shared chrome extraction

To support per-template views (see "Architecture decision" below) without triplicating code, extract from the current `MyPass/UI/EntryDetail/EntryEditView.swift`:

- `EntryEditFieldsCard` (currently a private card-styled container view) → widen its access level within the module so `CardEditView`/`NotesEditView` can reuse it, keeping the same `RoundedRectangle` + `UIShellMetrics` visual conventions used everywhere else in the app.
- `GroupPickerView` → already a standalone view; reused as-is, no changes needed.
- The favorite-star toolbar button (introduced in commit `ec7fea7`) → factor into a small shared `ToolbarContent` builder (e.g. `FavoriteToggleToolbarItem`) taking a `Binding<Bool>`, so Card and Notes get the identical star toggle behavior for free.
- The Cancel/Save toolbar buttons and their keyboard shortcuts (⌘Return to save, Esc to cancel) → factor into a small shared helper so all three edit views wire them identically.

This is the only refactor bundled into this feature, and it is scoped strictly to what's needed to support Card/Notes — no broader unrelated cleanup of `EntryEditView.swift`.

### Architecture decision: separate views per template

Three approaches were considered for how Card/Notes edit UI should be structured:

- **(A) Single `EntryEditView` with internal type-branching.** Smallest diff, but the file (already sizable) would grow into one large switch-driven file mixing Login/Card/Notes concerns together.
- **(B) Separate `CardEditView` / `NotesEditView` files, sharing extracted components (chosen).** Each template stays a small, focused, single-purpose file — matching this codebase's existing convention of one view per concern. Notes' custom markdown toolbar and Card's masked/formatted inputs each get room to be their own thing without a large conditional.
- **(C) Generic schema-driven form** (field specs as data, one generic renderer loops over them). Rejected as premature generality for only 3 fixed templates — Notes' custom toolbar+editor and Card's masked/formatted inputs don't fit a generic field-loop renderer, and there's no near-term need for a 4th template that would justify the abstraction.

**Decision: Approach B.**

## 4. Card template — `CardEditView.swift`

Same visual shell as Login (hero avatar + `EntryEditFieldsCard`, Cancel/Favorite/Save toolbar from §3), with these fields:

| Field | Source key | Protected | UI notes |
|---|---|---|---|
| Title | `Title` | no | same auto-resolve-if-blank behavior as Login (e.g. falls back to cardholder name if left blank) |
| Card Number | `CardNumber` | yes | masked by default with a reveal `eye` button (same pattern as the Password field today); light input formatting (grouping into 4-digit blocks) but no brand/Luhn validation |
| Cardholder Name | `CardholderName` | no | plain `TextField` |
| Expiry Date | `ExpiryDate` | no | plain `TextField`, stored as free-text `MM/YY` |
| CVV | `CVV` | yes | masked by default with a reveal button, same as Password |
| Group | — | — | `GroupPickerView`, unchanged |
| Favorite | `Favorite` | — | shared toolbar toggle from §3 |
| Extra fields | `additionalFields` | — | same dynamic add/remove key-value list as Login, for anything not covered by the fixed fields above (e.g. bank name, PIN) |

Detail view: `CardDetailView.swift`, a read-only sibling to `EntryDetailView`, with the same per-field copy-to-clipboard `contextMenu` (Copy / Show Large Type) as today; card number and CVV stay masked until revealed.

## 5. Notes template — `NotesEditView.swift`

- **Editor**: a `TextEditor` (multi-line, not the single-line-growing `TextField` Login's `Notes` field uses today) bound to the `NotesBody` string. Since this text is the entry's primary content, it gets the most vertical space in the form, positioned above/instead of the generic fields card.
- **Formatting toolbar**: a row of buttons above the editor — **B, I, U, H1, H2, H3, HR, inline code, code block**. Each button inserts/wraps the current text-editor selection with the corresponding markdown syntax:
  - B → `**...**`
  - I → `*...*`
  - U → `<u>...</u>` (CommonMark has no native underline syntax)
  - H1/H2/H3 → `# `, `## `, `### ` prefix
  - HR → `\n---\n`
  - inline code → `` `...` ``
  - code block → ` ```\n...\n``` `

  This is pure text manipulation on the bound `String` — no external editor library.
- **Rendering**: the read-only `NotesDetailView` renders `NotesBody` via Swift's built-in `AttributedString(markdown:)`.
  - **Known limitation** (explicitly accepted): `AttributedString(markdown:)` correctly renders inline styles — **bold**, *italic*, `inline code` — but does **not** render headers/HR/code-blocks as visually distinct blocks; they remain visible as their literal markdown characters (`#`, `---`, `` ``` ``) in the rendered text. This is a deliberate trade-off to avoid adding a third-party markdown dependency (e.g. swift-markdown-ui) to the project. The toolbar buttons still insert valid, portable markdown into the stored text regardless of how this app's own preview styles it.
- Title, Group picker, Favorite toggle: same shared chrome as Card/Login (§3).
- No extra-fields list for Notes — the template's entire purpose is one free-text body; adding a key/value extras list here would contradict that intent.

## 6. Smart categories & list display

- Extend the `SmartCategory` enum (`MyPass/UI/Shell/SmartCategory.swift`) with two new cases, `.cards` and `.notes`, alongside the existing `.all` / `.favorites` / `.codes` / `.security` / `.deleted`.
- `EntryCategoryFilter.entries(for:in:)` (`MyPass/UI/EntryList/EntryCategoryFilter.swift`) gets two new branches: `.cards` → `entry.entryType == .card`, `.notes` → `entry.entryType == .notes`. This is exactly the same filtering mechanism the existing `.favorites`/`.codes` cases already use — no new infrastructure.
- Sidebar (`MyPass/UI/Sidebar/GroupSidebarView.swift`, smart-category section): add two new rows, "Cards" and "Notes", with SF Symbols `creditcard` and `note.text` respectively, next to the existing Favorites/Codes/Security rows.
- Entry list rows: today, every row renders a `LetterAvatarView` (title-initial avatar; `iconID` is hardcoded to `0` everywhere and unused as a type signal). For Card/Notes entries, swap in the `creditcard`/`note.text` SF Symbols as the row's leading icon instead of a letter avatar, so entries remain visually distinguishable even in the mixed "All" list view.

## Testing considerations

- Unit tests for `EntryType` round-tripping through `KdbxXmlCoder` (an entry saved with `MyPass.EntryType = "Card"` reloads as `.card`; an entry with no such field reloads as `.login`).
- Unit tests for `EntryCategoryFilter`'s new `.cards`/`.notes` branches.
- UI/manual verification: creating a Card and a Notes entry via the new "+" menu, confirming they appear under their respective sidebar smart-category filters, confirming Login creation/editing is unaffected, confirming an old vault (entries with no `MyPass.EntryType` field) opens with all entries correctly shown as Login.
