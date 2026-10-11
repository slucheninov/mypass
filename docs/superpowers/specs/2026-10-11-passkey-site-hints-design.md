# Contextual passkey settings hints

The popup should not tell users to enable passkeys on every website. Show the
disabled-passkey message only in **This site** on an HTTPS page when either:

- Its exact hostname is in the bundled, manually maintained support catalog.
- The app returns a matching saved credential with `hasPasskey: true` for that URL.

The catalog in `ChromeExtension/shared/passkey-sites.js` records official support
documentation, a verification date and eligibility limitations for GitHub, Google,
Microsoft personal accounts, PayPal and Dropbox. This is a non-exhaustive UI hint;
listing a host does not guarantee support for a particular account or browser.
Unknown sites can still create and use passkeys normally. The main MyPass settings
retain the full passkey status and controls regardless of the current website.

Use exact HTTPS host matching, with no implicit subdomains or suffix heuristics.
Do not add runtime lookups, telemetry or content probes. Keep this catalog out of
credential matching, origin/RP validation and ceremony authorization. Updating
it requires checking the provider's official documentation and recording the date.

Favorites, search, global categories and non-HTTPS pages suppress the disabled
hint. Saved passkeys count only from the app's current-site lookup, never from a
global list or a previous site. Recompute the hint when status, context or matching
entries change so callback order cannot leave stale messages behind.

Validation covers exact/unknown/spoofed hosts, unsupported schemes, saved passkey
fallback, callback ordering, stale responses and category/search transitions.
