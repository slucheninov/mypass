# Unlock & Auto-lock Settings — Design

**Status:** Approved
**Date:** 2026-07-28
**Repo:** mypass (MyPass, macOS SwiftUI password manager, KDBX4-backed)

## Context

MyPass's `SecuritySettingsPane.swift` currently has three sections: Auto-Lock (a free-form `Stepper`, 1–120 minutes, bound to `AutoLockController`), Touch ID (a toggle that enrolls a Keychain-stored *derived key* via `VaultBiometricEnrollment`, gated by `BiometricKeyStoring`), and Clipboard. The Touch ID read path (`UnlockView.attemptBiometricUnlock`) is currently a placeholder — enrollment works but there is no real biometric unlock flow wired up yet.

A prior investigation (`.superpowers/sdd/2026-07-26-mypass-settings-redesign/final-review.md`) flagged that `KdbxDatabase.save(password:...)` regenerates the KDF `masterSeed`/salt on **every** save, which means any Keychain item storing a *derived key* tied to the vault's salt at enrollment time silently goes stale after the very next vault edit. This bug is non-blocking today only because the Touch ID read path isn't wired up yet.

This spec was originally scoped as "implement set/change/remove master password" as three separate actions. After clarifying with the user, the actual desired functionality is different and supersedes that framing entirely: it is a Bitwarden-style **Unlock** settings block (alternate unlock methods with session/re-auth timers) plus a redesigned **Auto-lock** block. There is no standalone "change master password" or "remove master password" UI — the KDBX master password itself continues to be set implicitly at first vault creation via the existing `UnlockView` flow, unchanged. "Removing the master password" as a user-facing concept is realized entirely through enabling device-based unlock (Touch ID / Mac password), so the user is rarely asked to type the real master password — not through literally deleting or blanking it.

## Goals

- Add an **Unlock** section to `SecuritySettingsPane.swift` with two independent alternate-unlock toggles and two re-auth timers.
- Replace the existing **Auto-Lock** section's free-form `Stepper` with a redesigned **Auto-lock** section using preset pickers, reusing the existing `AutoLockController`/`autoLockTimeoutMinutes` plumbing.
- Fix the Keychain-storage staleness bug as a side effect of wiring up real device-based unlock, by storing the actual master password (not a derived key) behind a biometric/device-owner-gated Keychain item.
- Retire the existing single "Touch ID" toggle/section and its `VaultBiometricEnrollment` derived-key approach in favor of the new mechanism described below.

## Non-goals

- No explicit "change master password" or "remove master password" text-field UI. Not in scope.
- No change to first-time vault creation (`UnlockView`'s implicit create-on-first-unlock behavior).
- No password strength meter or complexity rules (nothing like this exists elsewhere in the app for the master password).
- No sync-engine changes; this is local unlock/session behavior only.

## Design

### Unlock section (new)

Rows, in order:

1. **Toggle: "Unlock using Touch ID"**
2. **Toggle: "Unlock app with Mac password"** — independent of Touch ID; uses the macOS system account password as a separate alternate credential, not merely Touch ID's automatic fallback.
3. **Picker: "Unlock with device: For [8 hours]"** — how long a successful device-authenticated (Touch ID or Mac password) unlock stays trusted before the app requires a fresh device-auth prompt again.
4. **Picker: "Require account password: After [30 days]"** — hard backstop: regardless of how often device-unlock is refreshed, force entry of the real master password at least this often.

Preset options:
- "Unlock with device: For": 1 hour, 4 hours, 8 hours, 24 hours, Never
- "Require account password: After": 1 day, 7 days, 14 days, 30 days, 90 days, Never

### Auto-lock section (redesigned)

1. **Toggle: "Lock when device locks or sleeps"**
2. **Picker: "Lock after the device is idle for: [30 minutes]"** — replaces the current `Stepper`; same underlying `autoLockTimeoutMinutes` @AppStorage value and `AutoLockController`, different control only.

Preset options: Immediately, 1 minute, 5 minutes, 15 minutes, 30 minutes, 1 hour, 4 hours, Never.

### Keychain storage mechanism

Store the **actual master password string** (not a derived key) in a Keychain item, with `SecAccessControl` flags chosen from the two Unlock toggles:

| Touch ID | Mac password | ACL |
|---|---|---|
| on | off | `.biometryCurrentSet` (biometry required, no passcode fallback) |
| off | on | device-owner authentication without biometry |
| on | on | `.userPresence` (either satisfies it) |
| off | off | no Keychain item exists at all; behaves exactly like today (password field only) |

Whenever either toggle changes, the stored item must be re-created with the new ACL (delete + re-add; Keychain ACLs cannot be mutated in place). Storing the actual password (Keychain-protected, gated by the ACL above) instead of a derived key means the app always re-derives fresh from a live password at unlock time via the existing `vaultSession.unlock(password:)`, which sidesteps the salt-rotation staleness bug entirely — there is no "stale" state to go stale into.

This replaces `VaultBiometricEnrollment`'s existing derived-key approach; that type and its `"master"` Keychain account can be removed as this ships, rather than run in parallel with a second, different Keychain-backed mechanism.

### Timers

Two non-secret timestamps stored in `@AppStorage`: `lastDeviceUnlockDate` and `lastFullPasswordEntryDate`. These are timestamps only, not secrets, so `@AppStorage` is consistent with the existing project rule (see redesign spec line 183) against storing the master password, derived keys, or private key material there.

- On every successful **device-based** unlock (Touch ID or Mac password), update `lastDeviceUnlockDate`.
- On every successful **manual password-entry** unlock, update both `lastDeviceUnlockDate` and `lastFullPasswordEntryDate`.
- `UnlockView`, on appear, compares `now` against `lastDeviceUnlockDate + "Unlock with device" picker value` and `lastFullPasswordEntryDate + "Require account password" picker value`. If either window has elapsed, device-auth buttons (Touch ID / Mac password) are hidden and only the manual password field is shown, even if the toggles are otherwise on and a Keychain item exists.

### UnlockView changes

- Show the Touch ID button only if the Touch ID toggle is on, a Keychain item exists, and both timer windows above have not elapsed.
- Show a "Unlock with Mac Password" button under the same conditions for the Mac-password toggle.
- Both buttons authenticate via `LAContext` (biometric-only policy for Touch ID, device-owner-authentication policy for Mac password), then retrieve the stored password from Keychain on success and call the existing `vaultSession.unlock(password:)`.
- If both toggles are off, or both timer windows have elapsed, the view behaves exactly as it does today (password field only).

## Testing

New test coverage mirrors the existing `SecuritySettingsTouchIDTests.swift` conventions (real `VaultSession` + temp-dir `VaultFileStore`, fake `BiometricKeyStoring`, assertions on typed errors):

- Storing/retrieving the master password via each ACL combination (using the fake keystore's account/data behavior, not real Keychain/LocalAuthentication, which cannot be exercised in unit tests).
- Toggling either Unlock toggle re-creates the Keychain item under the new ACL and removes the old one.
- Timer logic: given a fixed `lastDeviceUnlockDate`/`lastFullPasswordEntryDate` and a fixed picker value, the "should show device-auth buttons" computation returns the correct boolean at boundary and past-boundary times.
- Auto-lock picker still round-trips into `autoLockTimeoutMinutes`/`AutoLockController` correctly for each preset value.

Real `LAContext`/Touch ID/Mac-password prompts cannot be exercised in unit tests; that boundary is faked the same way the existing Touch ID tests fake `BiometricKeyStoring`.

## Risks / open implementation notes

- macOS `SecAccessControl` has no direct "password-only, deny biometry" flag; achieving "Mac password only, Touch ID explicitly denied" may require `LAContext` policy selection at authentication time rather than purely at the ACL level. Flag this for the implementer to verify against actual `LocalAuthentication` API behavior on macOS before assuming the ACL table above is sufficient on its own.
- Removing `VaultBiometricEnrollment`/its `"master"` Keychain account is a breaking change for any user who previously enrolled Touch ID under the old mechanism; on first launch after this ships, stale old-format Keychain items should be deleted (best-effort, not a blocking migration) rather than left orphaned.
