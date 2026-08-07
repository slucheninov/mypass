# Chrome Extension — Unlock MyPass from the Popup

Status: approved 2026-08-07.

Follow-up to [2026-07-25-mypass-phase4-chrome-extension-design.md](./2026-07-25-mypass-phase4-chrome-extension-design.md)
and [2026-08-01-chrome-extension-popup-list-redesign-design.md](./2026-08-01-chrome-extension-popup-list-redesign-design.md).
Tracked as Stage 3 (`U1`–`U9`) in [docs/implementation/ROADMAP.md](../../implementation/ROADMAP.md).

## Problem

When the vault is locked, the popup shows "MyPass is locked" and a Retry button and
nothing else. The user must find and focus MyPass themselves, unlock it there, then come
back to the browser and reopen the popup. Retry is only useful *after* they have already
done all of that, so the panel's one action is the one action that cannot help yet.

## Goals

- One click in the popup gets the user to an unlock prompt.
- Touch ID works, not just the password field.
- The master password never enters the browser.
- No new consent surface: the pairing the user already granted is the gate.

## Non-goals

- **A password field in the popup.** See "Trust model" — this is the whole point of the design.
- **Unlocking without a pairing secret.** See "Pairing is the gate".
- **A settings toggle.** Pairing already expresses consent; see "Rejected alternatives".
- **Handling "MyPass is not running".** That is already a separate popup state
  (`app-unavailable`) with its own Retry / Open MyPass affordances. The locked panel is
  reachable only when the app answered `.locked`, which means it is running.
- **Any change to auto-lock, pairing, or credential-fill behavior.**

## Supersedes an earlier constraint

`2026-08-01-chrome-extension-popup-list-redesign-design.md` states: *"No unlock-from-extension,
password field, or unlock IPC in the popup."* This design reverses the first and third
clauses and **keeps the second** — there is still no password field in the popup, and the
extension still cannot unlock anything. What is added is a request to the app to show its
own unlock UI.

## Design

### Trust model

The extension never unlocks the vault. `requestUnlock` asks the app to *present* its
existing unlock screen; the master password is typed into the native app and never reaches
the browser process, the popup DOM, or any bridge message.

This is not merely a preference. Touch ID cannot run inside a Chrome extension —
`LocalAuthentication` is native-only — so any design that supports biometric unlock must
have the app show the prompt. Once the app is showing a prompt anyway, a password field in
the popup would add the worst-exposure path while buying nothing.

### Pairing is the gate

`requestUnlock` requires a valid pairing secret. This is possible while the vault is locked
because pairing lives in `KeychainExtensionPairingStore`, independent of the vault.

`requestUnlock` reads and writes nothing, so the residual risk is not data disclosure but
prompt-spam: without a pairing check, any local process could raise the window and trigger
Touch ID repeatedly, and a user conditioned to approve prompts may eventually approve one
they did not initiate. Requiring pairing removes that vector.

**Known consequence — the chicken-and-egg.** `startPairing` sits behind the locked gate, so
pairing requires an unlocked vault, while unlock-from-popup requires pairing. A user who is
both unpaired and locked therefore cannot use this feature and must open MyPass manually.
This is accepted: it is exactly today's behavior, so there is no regression, and the
alternative reintroduces the prompt-spam vector for the one case that needs it least.

### Flow

1. The popup renders the existing locked panel. When a pairing secret is present it also
   renders an **Unlock MyPass** button beside Retry.
2. Click sends `requestUnlock` over the existing native-messaging bridge.
3. The app validates pairing, raises its window, and re-triggers the Touch ID prompt.
4. Raising MyPass takes focus, which **closes the Chrome popup**. This is expected and is
   why the popup has no "waiting for unlock" state — the user would never see it.
5. The user unlocks in the app, returns to Chrome, reopens the popup, and sees credentials.

Commit `95ea2a9` removed window activation on pairing-code generation precisely because it
closed the popup. Here the focus change is the intended outcome, not a side effect.

### Wire protocol

New request:

```
.requestUnlock(token: String, pairing: String?)
```

New responses:

- `.unlockPresented` — the window was raised.
- `.unlockNotNeeded` — the vault was already unlocked, so nothing was raised.

`.unlockNotNeeded` is not symmetry for its own sake. In that case focus does not move and
the popup stays open, so it must re-query credentials; without a distinct response the
button would appear broken. Existing `.pairingRequired` covers the unpaired case.

### Locked-gate exception

`ExtensionBridgeService.handle` currently rejects everything before its `switch`:

```swift
guard vaultSession?.currentDatabase != nil else { return .locked }
```

Rather than bolting on a second special case, introduce a predicate —
`ExtensionBridgeRequest.isAnswerableWhileLocked` — so the exception list is data. Plan C
needs the same exemption for `getPasskeyProxyStatus`; with the predicate that becomes a
one-line addition. This is the hardening the roadmap already flagged against `C4`.

### Re-triggering the Touch ID prompt

`UnlockView` auto-prompts for Touch ID in `.onAppear`, guarded by the `@State` flag
`didAutoPromptDeviceUnlock`. Neither fires when an already-open window is merely refocused,
so activation alone would leave the user looking at a form nobody asked them to satisfy.

Add a `.requestDeviceUnlockPrompt` notification, mirroring the existing `.requestMainWindow`
pattern in `MainWindowActivator`, which `UnlockView` observes to re-run
`attemptDeviceUnlock()`. The existing `onAppear` logic is left untouched.

The re-prompt respects `canShowDeviceUnlockButton`: with Touch ID unenrolled or disallowed
nothing extra happens, and the password field is already there.

### Rate limiting

`ExtensionBridgeService` records the time of the last accepted request. Repeats within two
seconds are answered `.unlockPresented` but neither raise the window nor re-prompt.

This is defence in depth behind the pairing check, and it also stops an ordinary
double-click from stacking two Touch ID prompts.

### Order of checks

The handler evaluates in exactly this order, and the order is load-bearing:

1. **Pairing** — no valid secret → `.pairingRequired`, nothing else runs.
2. **Already unlocked** → `.unlockNotNeeded`. This precedes the debounce so that a click
   arriving just after a successful unlock always tells the popup to re-query, rather than
   being swallowed as a repeat and leaving the popup showing a stale locked panel.
3. **Debounce** — within two seconds of the last accepted request → `.unlockPresented`,
   no activation, no prompt.
4. Otherwise → invoke `onUnlockRequested`, record the timestamp, return `.unlockPresented`.

### App wiring

`ExtensionBridgeService` gains `onUnlockRequested: (() -> Void)?`, wired in `MyPassApp.init()`
exactly like the existing `onSaveProposal`: hop to main, activate the window, post the
prompt notification. The service itself never touches `VaultSession`.

## Files touched

| Path | Action |
|------|--------|
| `Packages/ExtensionBridgeKit/Sources/ExtensionBridgeKit/ExtensionBridgeMessages.swift` | `.requestUnlock` request, `.unlockPresented` / `.unlockNotNeeded` responses, `isAnswerableWhileLocked` |
| `Packages/ExtensionBridgeKit/Tests/ExtensionBridgeKitTests/ExtensionBridgeMessagesTests.swift` | Round-trip + predicate coverage |
| `MyPass/State/ExtensionBridge/ExtensionBridgeService.swift` | Handler, gate exception, debounce, `onUnlockRequested` |
| `MyPass/State/ExtensionBridge/LoopbackServer.swift` | Token extraction arm for the new case |
| `MyPass/App/MainWindowActivator.swift` | `.requestDeviceUnlockPrompt` notification name |
| `MyPass/UI/Unlock/UnlockView.swift` | Observe the notification, re-run `attemptDeviceUnlock()` |
| `MyPass/MyPassApp.swift` | Wire `onUnlockRequested` |
| `MyPassTests/ExtensionBridgeServiceTests.swift` | Handler tests |
| `ChromeExtension/popup.html` / `popup.js` | Unlock button on the locked panel |
| `ChromeExtension/background.js` | `requestUnlock` in `knownTypes` |
| `ChromeExtension/tests/unlockButton.test.js` (new) | Visibility + message-shape tests |
| `scripts/test.sh` | Run the new JS test |
| `RUN.md` | Manual checklist (Ukrainian) |

## Acceptance criteria

1. Locked + paired: the popup shows **Unlock MyPass**; clicking it brings MyPass forward
   showing the unlock screen with a fresh Touch ID prompt.
2. Locked + unpaired: no Unlock button; nothing is sent; no window activation.
3. `requestUnlock` without a pairing secret returns `.pairingRequired` and does not invoke
   the callback.
4. Already unlocked: returns `.unlockNotNeeded`, does not raise the window, and the popup
   re-queries credentials.
5. Two clicks within two seconds produce exactly one window activation and one Touch ID prompt.
6. Touch ID unenrolled: the window still comes forward with the password field; no error.
7. The master password appears in no bridge message and in no popup DOM node.
8. Existing locked-panel Retry behavior is unchanged.

## Testing

### Automated

- `ExtensionBridgeMessagesTests` — `requestUnlock` / `unlockPresented` / `unlockNotNeeded`
  encode and decode; `isAnswerableWhileLocked` is true only for the exception list.
- `ExtensionBridgeServiceTests` — answers while locked; `.pairingRequired` without pairing
  and no callback; callback fires once when paired and locked; `.unlockNotNeeded` when
  unlocked; debounce suppresses the second request; and `.unlockNotNeeded` wins over the
  debounce when a request arrives unlocked and within the window (the ordering above).
- `unlockButton.test.js` — button hidden without a stored pairing secret, shown with one;
  emits `{ type: "requestUnlock" }`; `unlockNotNeeded` triggers a credential re-query.

### Manual e2e notes (add to `RUN.md` Chrome section, Ukrainian)

Lock the vault, open the popup, press Unlock MyPass, confirm the app comes forward and asks
for Touch ID. Repeat with Touch ID disabled. Repeat unpaired and confirm no button appears.

## Rejected alternatives

- **Password field in the popup.** Shortest UX, but puts the master password in the browser
  process and still cannot do Touch ID. Rejected.
- **Hybrid** — Touch ID via the app, password in the popup as a fallback. Two attack
  surfaces and more code for a case the app already handles. Rejected.
- **Settings toggle, default off.** Pairing already expresses consent, and a
  default-off toggle would hide a feature whose purpose is to remove friction. Passkeys
  justify their toggle by hijacking the browser's system-wide WebAuthn; raising our own
  window is not comparable. Revisit only if a real complaint arrives.

## Follow-ups

- If the chicken-and-egg case proves annoying in practice, the locked panel could show a
  short hint ("open MyPass to pair this browser") in place of the button. Cosmetic; not
  required for this design.
