# KDBX4 Argon2 Interoperability — Vendoring a Real Argon2 Backend

**Date:** 2026-09-12
**Status:** Proposed

Related: [2026-07-21-keepasskit-vs-custom-parser.md](../spikes/2026-07-21-keepasskit-vs-custom-parser.md), the spike that chose to hand-write the KDBX4 engine in `Packages/MyPassKit` instead of vendoring the GPLv3 KeePassKit. That decision is why MyPass owns its own key derivation code today, and why fixing it means fixing this repository's code rather than swapping a dependency.

## Goal

Make MyPass open real KeePass and KeePassXC KDBX4 vaults, and keep the vaults MyPass writes openable by them, by replacing the Argon2 backend in `Packages/MyPassKit`.

Today MyPass can only open KDBX4 files whose Argon2 KDF parameters happen to match a narrow, non-standard shape MyPass itself produces. Any vault created or touched by KeePass 2.x or KeePassXC — which is to say, essentially every KDBX4 file that exists outside this codebase's own test fixtures — fails to open. This spec fixes the derivation so both directions of interoperability hold.

## Context — the problem, with evidence

`Packages/MyPassKit/Sources/MyPassKit/Format/KeyDerivation.swift:62-89` passes the KDBX header's `S` salt straight through to swift-sodium's `PWHash.hash`. swift-sodium rejects any salt that is not exactly 16 bytes before libsodium is ever called: the guard is at `PWHash.swift:118` (`guard salt.count == SaltBytes`), where `SaltBytes` is `crypto_pwhash_saltbytes()`, which is 16.

Real KDBX4 files use a 32-byte salt. Both Argon2id fixtures in `Packages/MyPassKit/Tests/MyPassKitTests/Fixtures/` carry an `S` of 32 bytes, with `M=67108864`, `I=14`, `P=1`, `V=0x13`. Opening `argon2id-aes256-gzip.kdbx` fails with the literal error `unsupportedFeature("KDF: sodiumFailure")`, reproduced directly against the current code.

This cannot be fixed by calling swift-sodium differently. Neither `crypto_pwhash` nor `crypto_pwhash_argon2id` has a salt-length parameter anywhere in its C signature — the 16-byte assumption is baked into the C ABI, not into swift-sodium's Swift wrapper. That is precisely why the fix here is a different backend rather than a different call into the same one.

Two further barriers compound the salt problem, and both are in scope together with it because fixing only the salt would still leave real-world files unopenable:

- `KeyDerivation.swift:70-72` rejects any parallelism other than 1. KeePass and KeePassXC do not constrain parallelism to 1.
- `KeyDerivation.swift:27-34` has no Argon2d branch; unrecognized KDF UUIDs fall through to `default: throw .unsupportedKdf`. Argon2d was the default KDF for older KDBX4 files (KeePassXC only switched its own default to Argon2id later), so a meaningful fraction of real files use it.

The limitation is currently known and surfaced to the user, not silently swallowed: `MyPass/UI/Settings/OpenExistingVaultSheet.swift:56-69` shows a warning about it, and two tests currently assert the failure as expected behavior — `KdbxCrossCompatibilityTests.testArgon2idGzipFixturesFailDueToSaltLengthLimitationNotGzip` and `KdbxDatabaseTests.testOpensRealKeePassXCReferenceFile`. Both flip to asserting success as part of this work (see Testing).

## Decisions

### Decision 1 — the backend: vendor phc-winner-argon2

Vendor the reference `phc-winner-argon2` implementation as a new SwiftPM C target inside `Packages/MyPassKit`. Pin an exact upstream commit and record it, together with the upstream licence text, in a vendoring note kept beside the vendored sources — the same way `ChromeExtension/vendor/jsQR.js` is handled elsewhere in this repo, so a future reader can tell at a glance what was imported and from where.

`phc-winner-argon2`'s dual CC0 / Apache-2.0 licence is compatible with MyPass being closed-source. This matters directly here: `docs/superpowers/spikes/2026-07-21-keepasskit-vs-custom-parser.md` already rejected KeePassKit as a dependency specifically because it is GPLv3, which would have forced MyPass's source to be disclosed. The same licensing bar applies to this decision, and the reference Argon2 implementation clears it.

Use the portable reference implementation (`ref`), not the SSE-optimized variant. The target platform is arm64 (Apple Silicon), and the SSE code path is an x86 intrinsics variant that would not compile, let alone run, there.

Rejected alternatives, with reasons:

- **A third-party Swift wrapper package.** Small, thinly maintained packages are a poor supply-chain bet for the key derivation function of a password manager — a single unmaintained dependency sitting directly on the path that turns a master password into a database key is exactly the kind of risk this product cannot take on casually.
- **A hand-written Swift Argon2 implementation.** This would mean self-rolled cryptography in the single most sensitive component of the product. The whole point of using a reference implementation is to inherit its scrutiny; writing a new one from scratch forfeits that.

### Decision 2 — swift-sodium stays

It was initially assumed that fixing Argon2 would let the swift-sodium dependency be dropped entirely. It cannot, and this decision is worth stating plainly because it makes the overall change smaller than it first appeared. Besides Argon2, swift-sodium backs two other primitives that have nothing to do with this bug:

- The outer ChaCha20 stream cipher, at `Packages/MyPassKit/Sources/MyPassKit/Format/ChaCha20StreamCipher.swift:46`.
- The inner Salsa20/ChaCha20 random stream, at `InnerRandomStreamCipher.swift:115` and `:123`.

Both call raw `Clibsodium` primitives directly and are unaffected by the Argon2 salt-length limitation. Only the KDF moves to the new vendored backend; swift-sodium remains a dependency of `Packages/MyPassKit` for these two ciphers.

### Decision 3 — the derivation itself

- Drop the `parallelism == 1` guard at `KeyDerivation.swift:70-72` and accept parallelism across the full Argon2 valid range, 1 to 2^24 - 1. The KDBX header type for `P` is `uint32`, so the value is validated against that range and rejected with a typed error outside it rather than being handed to the library unchecked. In practice real files use small values such as 2 or 4; the upper bound exists to reject a malformed or hostile header, not because large values are expected.
- Accept any salt of at least the Argon2 minimum of 8 bytes. A salt shorter than that is rejected with a typed error rather than falling through to a generic failure, so a malformed or truncated header is diagnosable instead of looking like a wrong password.
- Add an Argon2d branch alongside the existing Argon2id path at `KeyDerivation.swift:27-34`, sharing a single implementation parameterized by Argon2 type rather than duplicating the derivation call. The two types in play are `Argon2_id` and `Argon2_d`. Note that the reference library's enum also contains `Argon2_i`, a third algorithm KDBX4 does not use; passing it by mistake would not fail, it would quietly derive the wrong key, so the mapping from KDF UUID to type constant is worth a test of its own.
- Keep the existing version `0x13` guard as-is. Older Argon2 versions are not in scope.

**The unit trap.** This gets its own callout because it is the kind of mistake that does not fail loudly: KDBX gives the memory parameter `M` in **bytes**, while the reference library's `m_cost` parameter is in **kibibytes**. Passing the raw header value straight through silently derives a wrong key — the vault does not fail to open with an error, it fails to open looking exactly like the user typed the wrong password. The byte-to-kibibyte conversion must live in exactly one place in the code, and it must be pinned by a known-answer test so a future refactor cannot reintroduce the off-by-1024 error unnoticed.

### Decision 4 — the write path

`KdbxDatabase.save` at `KdbxDatabase.swift:186-194` currently mints a fresh KDF `VariantDictionary` on every save, with a 16-byte salt and `P=1` — the shape the old backend could tolerate. Going forward it writes a 32-byte salt and parallelism 2, keeping `M` at 64 MiB and `I` at 3, and always uses Argon2id, never Argon2d, for anything MyPass itself writes.

The consequence here is worth spelling out because it removes what would otherwise be a migration problem: `KdbxDatabase` is a struct that never stores the parsed header (`KdbxDatabase.swift:74-79`; `open` discards the header's KDF parameters once the database key is derived). Because of that, every save already regenerates KDF parameters from scratch regardless of what the file was opened with. That means existing MyPass vaults upgrade themselves to the new parameters automatically on their next save, with no migration code, no settings toggle, and no user prompt required. This is a deliberate choice over the alternative of preserving a file's original KDF parameters across a save — preserving them would require `KdbxDatabase` to start carrying header state it does not carry today, for no interoperability benefit, since the new parameters are themselves valid KDBX4.

### Decision 5 — error surface and UI

Map the vendored library's return codes into a typed error that carries the code, replacing the current opaque `.sodiumFailure` case. A caller — and a future debugger — should be able to tell a bad-salt-length rejection apart from an out-of-memory failure apart from a genuinely wrong password, rather than seeing one undifferentiated failure value for all of them.

The user-facing warning about Argon2id/32-byte-salt vaults not opening, in `MyPass/UI/Settings/OpenExistingVaultSheet.swift:56-69`, becomes false once this work lands. Removing it is part of this change, not a follow-up — shipping the fix while leaving a warning claiming the opposite would actively mislead users about what the app can now do.

## Testing

This is where the interoperability claim is either proven or it is just an assertion, so the plan here is specific on purpose.

- The existing independent known-answer test, `KeyDerivationTests.testTransformedKeyMatchesIndependentArgon2idKnownAnswer` (16-byte salt, vector generated independently via `argon2-cffi`), is **not** to be modified. It must pass unchanged against the new backend. That is the regression guarantee that the new backend did not silently change behavior for the one shape the old backend already handled correctly.
- Add new independently generated known-answer vectors covering: a 32-byte salt, and parallelism greater than one — for both Argon2id and Argon2d. These are the exact three constraints being lifted (salt length, parallelism, KDF type), so each needs its own pinned vector rather than relying on end-to-end fixture tests alone.
- Flip `KdbxCrossCompatibilityTests.testArgon2idGzipFixturesFailDueToSaltLengthLimitationNotGzip` and `KdbxDatabaseTests.testOpensRealKeePassXCReferenceFile` from asserting failure to asserting success.
- Regenerate the fixtures in `Packages/MyPassKit/Tests/MyPassKitTests/Fixtures/` with realistic parameters instead of the current `P=1` workaround, and add an Argon2d fixture that did not exist before. The pykeepass generation script used to build the existing fixtures is recorded in `docs/superpowers/spikes/2026-07-21-keepasskit-vs-custom-parser.md:19-68`; any regeneration must repeat the two pykeepass traps documented there — calling `del kp.kdbx.header['data']` before save, and manually relinking `next_byte` when adding a `VariantDictionary` key — or the regenerated fixtures will be silently malformed in the same way a naive first attempt was before.
- Prove the bidirectional claim literally, not just by inference from the KAT vectors: a test that saves a vault written by MyPass and then opens that same file with an independent third-party tool (KeePassXC or pykeepass, run out-of-process). Without this step, "MyPass-written vaults stay openable by KeePass/KeePassXC" is an assertion resting on matching the format on paper, not a demonstrated result.

## Non-goals and out of scope

- **The Twofish cipher.** Already rejected at `KdbxOuterHeader.swift:15-17`, and this work does not change that; the genuine KeePassXC reference file the spike examined, `Format400.kdbx`, uses Twofish together with Argon2d and is not checked into this repository, so even after this work adds Argon2d support that file would still need Twofish before it could be opened. That gap is a known, accepted one rather than an oversight.
- **Key files and hardware keys.** `KdbxDatabase.swift:317-322` builds a password-only composite key, and both of the type's public entry points take only a password. Supporting key files or hardware keys would change the public API of `KdbxDatabase` and reach into the unlock screen and the vault-creation screen, which is a materially larger change than replacing the KDF backend and is left for separate work.
- **The ArcFourVariant inner stream.** Not touched by this work; unrelated to Argon2.
- **KDBX3.** Not touched by this work; KDBX3 has its own key derivation path (AES-KDF, not Argon2) and is out of scope for an Argon2-focused change.

## Risks

- **Derivation speed.** The portable reference implementation of Argon2 is not the fastest available build (that would be the SSE-optimized variant, rejected in Decision 1 for platform reasons), and derivation time directly determines how long unlocking a vault takes on real hardware. This must be measured before and after the change on the target parameters (`M=64 MiB`, `I=3`, `P=2`) rather than assumed acceptable; if it is not acceptable, that is a finding for implementation to surface, not something this spec can settle in advance.
- **Build integration.** The vendored C target must build correctly not only under `swift test` in isolation, but inside the app target, whose Xcode project (`MyPass.xcodeproj`) is generated by XcodeGen from `project.yml`. A C target that builds cleanly under SwiftPM can still need explicit module-map or header-search-path handling to build correctly once pulled into an Xcode-generated app target, so this path needs its own explicit verification rather than being assumed to follow automatically from the package tests passing.

## Follow-ups

- Key file and hardware key (e.g. YubiKey challenge-response) support, once there is a plan for the `KdbxDatabase` public API change it implies.
- Twofish cipher support, which combined with this work's Argon2d support would finally make `Format400.kdbx` openable.
- KDBX3 support, if a demonstrated need for it arises.
