# MyPass — Phase 7 (Localization): Design

Date: 2026-07-26  
Status: approved

## Goal

Multi-language UI for the macOS app and Chrome extension. Initial locales: **en** (source/default), **uk**, **de**. Additional languages are added by extending localization catalogs only — no code changes required beyond catalog entries.

## Schedule

Phase **7** in the project roadmap. Execute **after Phase 4b** (Safari + shared WebExtension layer) and **before Phase 5** (iOS/iPadOS + AutoFill) so iOS inherits the localization infrastructure when that phase begins.

## Approach

### macOS app

- **String Catalog:** `Localizable.xcstrings` with English as the source locale.
- **API:** Swift `String(localized:)` (and related catalog APIs) for all user-visible strings.
- **Settings override:** Settings → Language offers **System**, **English**, **Українська**, **Deutsch**. The chosen preference is persisted and applied as the app's preferred locale at runtime.

### Chrome extension

- **Manifest:** `default_locale: "en"`.
- **Catalogs:** `_locales/{en,uk,de}/messages.json`.
- **API:** `chrome.i18n.getMessage` for popup, content script, and banner strings.

### Language override behavior

| Surface | v1 behavior |
|---|---|
| macOS app | Settings language override applies to the app UI (System follows macOS locale). |
| Chrome extension | Follows the **browser UI locale** via standard `chrome.i18n` — the standard Chrome extension model. |

Syncing the Chrome extension to the app's Settings language preference is **out of v1 scope**. Passing a preferred locale from the app to the extension via the native-messaging bridge is a possible future enhancement if users need Chrome to match the app setting rather than the browser locale.

## Out of Scope

- **Vault content** — group names, entry titles, and other user-authored text remain as stored; not translated.
- **iOS/iPadOS** — Phase 5 adopts the same String Catalog infrastructure; iOS UI localization is not part of Phase 7.
- **Automated translation CI** — no machine-translation pipeline or translation-bot checks in this phase.
- **Phase 4b Safari details** — beyond noting that shared WebExtension JS should use the same i18n helpers when Phase 4b lands.

## Compatibility

- **English is the source of truth** in all localization catalogs (Swift String Catalog and Chrome `_locales`).
- Root **`RUN.md` stays Ukrainian** — it is a developer runbook, not product UI, per the project language rule (`.cursor/rules/language.mdc`).

## Acceptance Criteria

- All user-visible macOS strings go through the String Catalog (`String(localized:)`).
- **en**, **uk**, and **de** catalogs are complete for macOS UI.
- Chrome popup, content script, and banner strings are localized via `_locales` for **en**, **uk**, and **de**.
- Settings language override changes macOS UI without code changes.
- Adding a new language requires catalog entries only (documented procedure in the phase plan).

## Risks

| Risk | Mitigation |
|---|---|
| String key drift between Swift String Catalog and Chrome `_locales` | Shared naming convention; checklist when adding strings; review during PR |
| Incomplete coverage (hard-coded strings left in code) | Grep/audit pass before phase sign-off; acceptance criteria require full catalog coverage |
| Recycle Bin display name vs stored KeePass group name | Keep the stored group name as `"Recycle Bin"` in English in the vault; localize the UI label separately when displaying the known recycle-bin UUID |
