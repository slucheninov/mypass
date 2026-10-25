# Passkey AAGUID and community registry submission

Date: 2026-10-25

## Why

Until now MyPass wrote an all-zero AAGUID into the attested credential data of every
passkey it registered. An all-zero AAGUID identifies nothing, so a relying party that
lists a user's passkeys (Google's "Passkeys" page, for example) can only show a generic
entry. Many sites resolve an AAGUID to an authenticator name and icon through the
community registry
[passkeydeveloper/passkey-authenticator-aaguids](https://github.com/passkeydeveloper/passkey-authenticator-aaguids).
MyPass now writes a fixed AAGUID (`PasskeyCeremony.mypassAAGUID`), and this document
records how to register that AAGUID so it can be labelled "MyPass".

Attestation is unchanged: the default `none` conveyance still produces fmt `none` with an
empty statement. The AAGUID names the authenticator model; it proves nothing about the
device. Whether a browser forwards the AAGUID for proxied (WebAuthn proxy) responses is not
verified here.

## The AAGUID

```
94803471-f8b4-48f9-98ff-fc4ac1a92af8
```

Generated once for MyPass. It is not secret, not per-credential, and must never change:
registry entries and relying-party policies key on it. In authData it sits at bytes 37..<53
(rpIdHash 32, flags 1, signCount 4, then the 16 AAGUID bytes).

## Registry format (as found upstream, 2026-10-25)

From the upstream README and `aaguid.json.schema`:

- The top-level key is the AAGUID, which must be lowercase.
- Each entry requires `name`, the friendly provider name shown in relying-party UIs.
- `icon_dark` and `icon_light` are optional, each a base64 SVG data URI matching
  `^data:image/svg+xml;base64,(.*)$`; `icon_dark` is for dark backgrounds, `icon_light` for light.
- Icons must be square and fully vector based. Embedded raster images (PNG, JPG) are not allowed.
- The contributor's GitHub profile should be complete, including an organization name, and
  contact information should be on the organization's domain; maintainers may ask for
  out-of-band verification otherwise.
- Changes are validated against the JSON schema (for example with `ajv`); validation also
  runs automatically when the PR is opened.

## Entry to add to the registry JSON

```json
"94803471-f8b4-48f9-98ff-fc4ac1a92af8": {
  "name": "MyPass",
  "icon_dark": "data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSI0MDAiIGhlaWdodD0iNDAwIiB2aWV3Qm94PSIwIDAgNDAwIDQwMCI+PGcgZmlsbD0iIzdDQzk2QiI+PHBhdGggZmlsbC1ydWxlPSJldmVub2RkIiBkPSJNMjAwIDEwYTkyIDkyIDAgMSAwIDAuMDEgMFpNMjAwIDczYTI4IDI4IDAgMSAxIC0wLjAxIDBaIi8+PHBhdGggZD0iTTE2NSAxNTBIMjM1VjE2MEwyNTAgMTgwVjE5OEwyMzIgMjE1VjIzMkwyNTAgMjUwVjI2OEwyMzIgMjg1VjMwMkwyNTAgMzIwVjM0MEwxOTAgMzg1UTE2NSAzOTIgMTY1IDM3MFoiLz48L2c+PC9zdmc+Cg==",
  "icon_light": "data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSI0MDAiIGhlaWdodD0iNDAwIiB2aWV3Qm94PSIwIDAgNDAwIDQwMCI+PGcgZmlsbD0iIzRGQTgzRiI+PHBhdGggZmlsbC1ydWxlPSJldmVub2RkIiBkPSJNMjAwIDEwYTkyIDkyIDAgMSAwIDAuMDEgMFpNMjAwIDczYTI4IDI4IDAgMSAxIC0wLjAxIDBaIi8+PHBhdGggZD0iTTE2NSAxNTBIMjM1VjE2MEwyNTAgMTgwVjE5OEwyMzIgMjE1VjIzMkwyNTAgMjUwVjI2OEwyMzIgMjg1VjMwMkwyNTAgMzIwVjM0MEwxOTAgMzg1UTE2NSAzOTIgMTY1IDM3MFoiLz48L2c+PC9zdmc+Cg=="
}
```

Add it to `combined_aaguid.json` or whichever file the upstream README names at submission
time, keeping the existing key ordering convention.

## Icon provenance

The repository has only raster artwork (`AppIcon.appiconset` PNGs and
`BrandKey.imageset`), and the registry forbids embedded rasters. The icons here are a
hand-drawn vector re-creation of the MyPass key mark (the green key from `BrandKey`),
flat colour, 400x400 viewBox, no embedded images:

- `assets/mypass-aaguid-icon-light.svg`: fill `#4FA83F`, for light backgrounds.
- `assets/mypass-aaguid-icon-dark.svg`: fill `#7CC96B` (lighter green), for dark backgrounds.

They are a faithful-but-simplified approximation, not an export from a design source. If the
brand owner has an original vector (Figma or similar), prefer that, re-encode it with
`base64 < icon.svg | tr -d '\n'`, and replace the data URIs above.

## Submission steps (not yet done)

1. Fork `passkeydeveloper/passkey-authenticator-aaguids` and make sure the GitHub profile
   used has a complete profile with an organization name and a contact address on the
   organization's domain.
2. Add the entry above to the registry JSON in the fork.
3. Validate against `aaguid.json.schema` (for example `ajv validate -s aaguid.json.schema -d <file>`).
4. Open a PR explaining that MyPass is a KDBX4-based macOS password manager with passkey
   support and linking the project; respond to any maintainer verification request.
5. After the merge, track when downstream consumers pick it up.

## Caveat

Whether Google (or any other site) shows "MyPass" depends on that site ingesting the
registry. Timing is outside our control and may take weeks or never happen. Passkeys
registered before this change keep the all-zero AAGUID and will not be relabelled;
only newly created passkeys carry the MyPass AAGUID.
