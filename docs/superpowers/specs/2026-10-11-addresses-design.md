# Address entries and explicit browser autofill

## User need

Store home, work, and other reusable addresses in the encrypted MyPass vault and choose one when filling an address form. Addresses need their own category and editor; they are not login credentials associated with one website.

## Vault model and native UI

An address is a normal KDBX entry with `MyPass.EntryType = Address`. The title is independent of its Home / Work / Other label and defaults to that label when blank. Structured values use protected `MyPass.Address.*` custom fields. They remain compatible with KDBX encryption, synchronization, groups, favorites, deletion, and existing entry history. Saving an edit preserves the existing entry identity, history, and unrelated fields.

Fields: label, fullName, givenName, familyName, organization, addressLine1, addressLine2, city, region, postalCode, countryCode, countryName, phone, email. All are strings; optional values are empty. Full name is never split into guessed name parts. A missing full name is represented for display/autofill by joining explicit given and family names. Country selection is explicit and stores its ISO code with an English name; no locale-based country inference occurs.

Addresses appears in the sidebar with its own count and filter. Add → Address opens a scrollable editor with a group selector, favorite control, address fields, and notes. The detail view provides copy actions. Category lists exclude the recycle bin (including nested deleted groups). Search includes address content. Structured fields do not appear as generic editable custom fields; unrelated fields are preserved. The menu bar displays an address summary and opens the same editor.

## Usage

1. In the MyPass app, open the **+ / Add** menu and choose **Address**. Set a title, Home / Work / Other type, and the address fields you need; save the entry in the desired group.
2. Open a website's address form. In the MyPass extension, choose **Addresses**, then select an entry. Address entries selected from All, Favorites, or Search use the same address flow.
3. Review the destination hostname and choose the form shown in the popup. A unique focused address group narrows the choices; otherwise the popup offers the eligible forms separately. Confirming a form fills that group and reports the number of fields filled.
4. Review the website's values before submitting. If the website rebuilds its form during filling, MyPass stops and asks you to review any values already filled before trying again.

Creation and editing are available in the native app. There is no extension Add Address editor. No supported form produces an explanatory message instead of silently succeeding.

## Bridge contract

The existing `listEntries` request accepts `category: "addresses"`. Browse summaries set `entryType: "Address"` and use the full name as the username summary; street and postal data are not included in browse responses.

An explicit user selection sends `fillAddress` with `id`, `url`, launch token, and pairing secret. The app requires an authorized pairing, an unlocked vault, a valid HTTP(S) destination without URL credentials, and a live Address entry. Unlike logins, addresses are deliberately reusable on unrelated websites, so URL/domain matching does not authorize the entry. The extension's selected document and form provide the destination boundary. A successful request counts as deliberate auto-lock activity.

Response shape:

```json
{
  "type": "address",
  "address": {
    "id": "entry-uuid", "label": "Home", "fullName": "", "givenName": "", "familyName": "",
    "organization": "", "addressLine1": "", "addressLine2": "", "city": "", "region": "",
    "postalCode": "", "countryCode": "", "countryName": "", "phone": "", "email": ""
  }
}
```

Address entries are excluded from website login discovery and credential filling, even if an imported/custom-edited address carries a URL. The existing flat Login/Card/Notes `createEntry` payload explicitly rejects Address; create and edit addresses in the native app.

## Browser interaction and safety

Addresses is a popup category. Selecting an address begins an explicit fill flow for the top document. Discover forms with standard HTML autocomplete tokens, including name and optional contact fields; require address-specific tokens before treating a group as an address form. Group by form owner and autocomplete section/shipping/billing identifiers. A unique focused group may narrow the choices, but the user still confirms its form. Without that focus, multiple eligible groups are offered separately. Never fill every address group or frame. A scope with duplicate field tokens, or both a combined street-address control and separate address lines, is ambiguous and is not offered.

Bind the operation to the captured tab, frame, document, origin, and selected form before requesting address data. Reject stale navigation, changed form context, or delivery failure. Do not relay address values through extension storage or expose them as a popup response. Accept the address-fill command only from the extension popup, not arbitrary content-script messages.

Fill only supported, visible, editable controls. Skip unknown or empty values and hidden, disabled, readonly, password, OTP, and unrelated login fields. Use explicit stored given/family names; do not guess name decomposition. Match country select options against the stored ISO code or country name by equal value or visible text, ignoring surrounding whitespace and letter case. Require exactly one matching enabled option. Select options are rechecked at the time of each write, because earlier input events may change a dependent select. Never auto-submit, auto-save address data from a page, or mix the operation with password-save banners.

## Eligibility and limits

The supported autocomplete fields are `name`, `given-name`, `family-name`, `organization`, `street-address`, `address-line1`, `address-line2`, `address-level2`, `address-level1`, `postal-code`, `country`, `country-name`, `tel`, and `email`. An optional `section-*` prefix and then `shipping` or `billing` scope are recognized. A group must contain a street, locality, region, or postal-code field; an isolated login email field does not qualify.

The main page is supported; iframe forms, shadow-root forms, custom non-native widgets, and forms without the supported autocomplete annotations are not. Native text/email/tel inputs, textareas, and single-select controls are eligible only when visible and editable. Unknown fields and empty profile values remain unchanged. For `street-address`, stored lines are joined with a newline in a textarea and comma-space in a single-line input. Fields may remain unfilled when the site expects a value the profile does not provide or a select has no unique match. There is no guessing of country names, name parts, or missing values.

## Verification

Native checks cover protected field storage, KDBX encrypted roundtrip, create/edit preservation, names, category counts/search/trash, and bridge authorization/type/destination boundaries. Browser checks cover standard tokens, grouped forms, selects, empty/hidden/disabled controls, document routing, and acknowledgement errors. A manual fixture exercises independent shipping and billing forms and unrelated login controls. Run the complete repository test script before marking implementation complete. Live behavior on arbitrary websites is outside deterministic test coverage; unsupported unannotated/custom controls remain unchanged.

### Observed verification boundary

Focused native and shared-package tests passed. A browser fixture using the actual address helper and a synthetic profile verified independent shipping (six fields) and billing (four fields) fills, while preserving hidden, unrelated login, ambiguous, and empty-profile fields. A popup preview at 360 × 600 with mocked bridge responses verified the form chooser, acknowledgement state, and control layout without clipping.

These checks did not exercise the installed extension through the native bridge against a real vault or a third-party checkout. The full integrated test gate passed (986 Swift cases, including 23 skips, and 25 JavaScript suites), and MyPass plus ChromeHost built successfully. This preview and the automated gate do not establish live end-to-end behavior.
