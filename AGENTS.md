# AGENTS.md

Shared instruction file for every coding agent working in this repository (Claude Code, Cursor, Codex, and anything else that reads `AGENTS.md`). `CLAUDE.md` points here; there is no second source of truth.

User instructions in the chat ALWAYS win. Everything below is the default for when the user did not specify otherwise.

---

# 1. The project

**MyPass** is a native macOS password manager built on the KeePass **KDBX4** vault format, paired with a Chromium browser extension for autofill, TOTP and WebAuthn passkeys.

| Component | Stack | Notes |
|---|---|---|
| macOS app | Swift + SwiftUI, macOS 14.0+ | bundle id `com.mypass.app`, `MARKETING_VERSION 0.5.1` |
| Native messaging host | Swift CLI, target `ChromeHost` | bundle id `com.mypass.chromehost` |
| Browser extension | Plain JavaScript, MV3, no bundler | `minimum_chrome_version: 127`, pinned extension id `hjijbabodfldconmhdcdphlbgaajkejn` |

There is no `package.json`, no Node toolchain and no Electron. Build manifests are `project.yml` (XcodeGen) plus three `Package.swift` files under `Packages/`. `MyPass.xcodeproj` is generated and gitignored — regenerate it, never edit it.

Third-party dependencies: `swift-sodium` (Argon2id), `Citadel` + `swift-nio` + `swift-nio-ssh` (SFTP sync), vendored `jsQR.js` in the extension.

## Repo layout

| Path | Contents |
|---|---|
| `MyPass/` | SwiftUI app. The process entry point (`@main`) is `AppLauncher` in `App/SingleInstance/`; `MyPassApp` is the SwiftUI `App` it starts and is no longer `@main`. Subfolders `App/ Import/ Models/ Security/ State/ Storage/ UI/` |
| `MyPass/Resources/` | String Catalogs: `Localizable.xcstrings` (app UI) and `InfoPlist.xcstrings` (usage descriptions), each with `en`, `uk` and `ru` entries |
| `MyPass/State/ExtensionBridge/` | `LoopbackServer`, `ExtensionBridgeService`, `ExtensionPairingManager/Store`, `ExtensionEntryMatcher`, `PasskeyCeremony` |
| `MyPass/UI/` | `Sidebar/ Settings/ MenuBar/ Shell/ EntryList/ EntryDetail/ ExtensionPairing/` |
| `MyPassTests/` | XCTest suite for the app target (auto-lock, passkeys, TOTP, pairing, vault stores) |
| `Packages/MyPassKit/` | KDBX4 engine, TOTP generator, password generator, Public Suffix List |
| `Packages/SyncKit/` | `SFTPBackend`, `iCloudBackend`, `LocalFolderBackend`, `MergeEngine`, `SyncEngine`, TOFU host-key validator |
| `Packages/ExtensionBridgeKit/` | Shared app-to-host protocol: messages, native messaging codec, token store |
| `ChromeHost/` | `main.swift`, `Relay.swift`, entitlements. The native messaging manifest is generated per browser by `scripts/dev.sh install-host`, not stored here. |
| `ChromeExtension/` | `manifest.json`, `background.js`, `content.js`, `popup.html/js`, `shared/`, `vendor/`, `tests/` |
| `scripts/` | Three maintained scripts: `dev.sh` (generate, build, run, install-host, package), `test.sh`, `update-password-rules.sh`. `scripts/package/INSTALL.txt` ships inside the macOS artifact. |
| `.github/` | `workflows/ci.yml`, issue forms, pull request template, `dependabot.yml` |
| `docs/implementation/ROADMAP.md` | The only tracked file under `docs/implementation/`. Lists only unfinished work; delete an item when it is implemented and verified. |
| `docs/superpowers/` | Local-only and gitignored (`/docs/superpowers/`): `plans/`, `specs/`, `spikes/`, `drafts/`, named `YYYY-MM-DD-slug[-design].md`. `drafts/` holds files that are not published yet (for example `SECURITY.draft.md`). Never commit anything from it and never link to it from tracked files. |
| `LICENSE`, `THIRD_PARTY_NOTICES.md` | Apache-2.0 root license and the notices for vendored and linked third-party code. Both ship inside the artifacts. |
| `RUN.md` | Ukrainian run + manual verification checklist. Do not translate it. |

## Build, run, test

```sh
brew install xcodegen                          # prerequisite, plus Xcode
./scripts/dev.sh generate                      # xcodegen generate -> MyPass.xcodeproj
./scripts/dev.sh build [--unsigned]            # app + ChromeHost into ./build
./scripts/dev.sh run                           # ask every running MyPass to quit (up to 15 s), then build, then open the new build
./scripts/dev.sh install-host [--host PATH] [--install-root DIR]   # ChromeHost + native messaging manifests
./scripts/dev.sh package [--out DIR]           # unsigned, ad-hoc-sealed development zips into ./dist
./scripts/test.sh [--ci] [--no-js]             # full suite
```

`scripts/test.sh` runs `xcodebuild test -scheme MyPass`, then `swift test` in each of the three packages, then every `ChromeExtension/tests/*.test.js` suite (35 today, discovered by glob; each in its own `node` process, failures aggregated). There is no JS test framework — each test file is a plain node script. Without `node` a local run fails unless `--no-js` is passed, which prints that the JS suites were not run. `--ci` rejects `--no-js`, requires every tool, and builds unsigned through command-line overrides only (`project.yml` is untouched). `--no-js` is never a way to report a change as tested when it touches `ChromeExtension/`. Hosted app tests run with `-testLanguage en` so assertions see English text, and `LocalizationCatalogTests` fails when any catalog key lacks a translated `uk` or `ru` entry.

Local builds keep the stable team signing from `project.yml`. Unsigned output exists only behind explicit flags (`--unsigned`, `--ci`, `package`); unsigned artifacts are for development and inspection, and Touch ID and the Keychain-backed app-to-host exchange are expected to be limited there (untested).

Opt-in integration tests: `MYPASS_KEYCHAIN_TESTS=1`, `MYPASS_SFTP_INTEGRATION_TESTS=1` (needs `Packages/SyncKit/Tests/Fixtures/docker-sshd/run.sh`), `MYPASS_ICLOUD_INTEGRATION_TESTS=1`.

The extension has no build step. Load `ChromeExtension/` unpacked and reload it on `chrome://extensions` after editing JavaScript. Manual end-to-end fixtures are served with `python3 -m http.server 8765` from `ChromeExtension/tests/fixtures`; the checklist lives in the second half of `RUN.md`.

**No linter or formatter is configured** anywhere in this repo. Match the style of the surrounding code by hand.

**CI is a second check, not a substitute.** `.github/workflows/ci.yml` runs `scripts/test.sh --ci` and `scripts/dev.sh package` on pull requests, on pushes to `master` and on manual dispatch. It builds unsigned on arm64, so a green run proves logic only, not the runtime behaviour of a signed build, and it reports after the fact. Look at the Actions run for the real result instead of assuming one, and run `./scripts/test.sh` yourself before claiming work is done.

## Architecture essentials

- **Vault engine.** `Packages/MyPassKit` implements KDBX4 from scratch: outer and inner headers, `VariantDictionary`, HMAC block streams, AES-256-CBC and ChaCha20, header authentication, Argon2id and Argon2d via a vendored `phc-winner-argon2` C target (`CArgon2`), supporting any salt length the format allows and parallelism beyond one. swift-sodium is retained for the ChaCha20 and Salsa20 stream ciphers.
- **Single instance.** `AppLauncher` runs before `MyPassApp.init` and elects one owner through `SingleInstanceCoordinator`, `InstanceLock` (an `flock` file in the app's own support directory) and a versioned two-phase probe/commit exchange over `DistributedNotificationCenter` (the notification name embeds the bundle id and `v2`, and the payload rides in the notification `object` because a sandboxed sender's `userInfo` is dropped). Peers are found through `NSRunningApplication` (the launcher creates `NSApplication` first so LaunchServices can see it) and identified by pid plus start time from the kernel process table. A launch that loses touches no defaults, Keychain, bridge or vault. The newer launch wins; the older copy quits through `QuitFlushCoordinator` (flush, or a Cancel / Quit Anyway prompt on a failed or timed-out save). A live peer that never answers the probe (a build from before the guard, a test host, a foreign process) or an acknowledged peer that does not exit within 15 s makes the new launch fail closed; a sandboxed copy that runs this guard takes part normally. Test hosts and previews are exempt. `scripts/dev.sh run` quits every running copy before it builds, and never force-kills.
- **Session state.** `MyPass/State/VaultSession.swift` is an `ObservableObject` holding `enum VaultState { locked, unlocked(KdbxDatabase) }`, with debounced background persistence and a sync merge on save.
- **Auto-lock and device unlock.** `AutoLockController`, `AutoLockIdleTimeout`, `UnlockWindowPolicy`, `DeviceUnlockPromptCoordinator`, plus `Security/BiometricKeyStore.swift` guarding a Keychain access group behind `LAContext`.
- **Signing constraint.** `project.yml` pins a stable `DEVELOPMENT_TEAM`. Ad-hoc signing changes the cdhash on every build and silently breaks the biometric key ACL. Do not switch it to ad-hoc.
- **Browser bridge, three hops.** `background.js` talks Chrome native messaging to `ChromeHost`, which relays over a TCP loopback on `127.0.0.1` at an OS-assigned port served by `LoopbackServer.swift`. Endpoint and token are shared through the Keychain-backed `ExtensionBridgeTokenStore`; the host answers `app_not_running` when no token exists.
- **Bridge protocol.** `ExtensionBridgeMessages.swift` holds a 15-case request enum with hand-written `Codable`. Every request carries a per-launch token and an optional pairing token. Switches over it are deliberately exhaustive with no `default` — add the new case everywhere rather than silencing the compiler.
- **Pairing.** A 6-digit code shown in the app, valid 120 seconds, entered in the popup. Per-browser pairings are revocable in Settings, Browser tab.
- **Passkeys.** The extension proxies create and get ceremonies through Chrome's `webAuthenticationProxy` API to `PasskeyCeremony.swift`. Credentials live in KeePassXC-compatible `KPEX_PASSKEY_*` custom fields, hidden from the normal custom-field UI. The app-side toggle is authoritative over the extension's state.
- **Domain matching** uses the bundled Public Suffix List for registrable-domain comparison, never naive suffix heuristics. Frame-level matching is hostname-only, and save prompts are top-frame only.
- **Sync.** `SyncKit` exposes a pluggable `StorageBackend` with SFTP, iCloud Drive and local folder implementations, plus `MergeEngine` and `SyncCheckpointStore` for three-way merge.
- **In-browser prompts.** Save-login, save-2FA and the picker's settings row are not page banners. The content script only sends `requestPrompt` / `openMyPassSettings`; `background.js` validates the sender (tab, frame, documentId, url), re-reads `offerSaveLogin` / `offerSaveTotp`, and keeps the pending record (secret included) in `chrome.storage.session` for 120 s (`shared/prompt-record.js`). `openMyPassPrompt` tries `action.openPopup`, then one `prompt.html` window, then the `!` badge; `popup.html` and `prompt.html` render the same redacted card (`shared/prompt-card.js`) and answer with `{ promptId, action }` only. Passkey ceremonies use the same opener but never the window. Only a trusted submit with a live `navigator.userActivation` may raise a save-login prompt, at most one auto-opened surface per tab per 30 s; the gesture-less 2FA sweep is badge-only; a captured save-login survives a same-origin (scheme, host, port) navigation of its tab, nothing else does.
- **Content script safety.** The inline fill icon lives in a closed shadow root, defends against hostile page CSS with `!important`, gates actions on `event.isTrusted`, and never mutates the site's own `<input>` elements.

## Conventions

- **Language: English is the source language** for code, comments, commit messages, docs, plans, specs, error messages and extension copy. App UI strings are written in English in code and translated into Ukrainian (`uk`) and Russian (`ru`) in the String Catalogs under `MyPass/Resources/` (`Localizable.xcstrings`, plus `InfoPlist.xcstrings` for the `Info.plist` usage descriptions, whose English source stays in `project.yml`). Add a translation for every new or changed UI string in the same change. Cyrillic belongs only in `*.xcstrings` and root `RUN.md` (Ukrainian, must not be translated); every other doc stays English, so when a change touches a doc that still carries Cyrillic elsewhere, translate it to English as part of that change. The extension has no `_locales` yet and German is not shipped; both stay on the roadmap.
- **Commits: Conventional Commits with a scope**, lowercase imperative subject, no trailing period. Scopes in use: `app`, `extension`, `chrome`, `scripts`, `entry-edit`, `ci` (workflow), `docs` (documentation only). Example: `fix(app): reset auto-lock idle timer on deliberate extension activity`.
- **Long explanatory comments are a feature here.** The codebase records *why* a constraint exists (signing and cdhash, libsodium salt length, `pgrep` under `set -e`, queue choices). Preserve that rationale when editing; do not strip it as noise.
- **Documentation habit.** Substantial features get a local-only spec in `docs/superpowers/specs/` and plan in `docs/superpowers/plans/` (gitignored, so they are working notes and not repository documentation). `docs/` itself holds documentation only: `docs/implementation/ROADMAP.md` lists only unfinished work: delete an item once it is implemented **and** its tests pass (a manual-only item, once the manual check has actually been walked). Items are open `[ ]` boxes until then; do not tick one for partly done work. Do not add other implementation notes, captures or completed-work logs to `docs/`.
- **Shell scripts** are `set -euo pipefail`, resolve the repo root themselves, and preflight-check required commands. Keep new scripts in that shape.
- **Licensing.** The project is Apache-2.0 (root `LICENSE`, unfilled canonical text, no root `NOTICE`). Any change that adds, removes or bumps a dependency, or re-vendors a file, updates `THIRD_PARTY_NOTICES.md` in the same change; see `CONTRIBUTING.md`.
- **Gitignored, do not commit or hand-edit:** `*.xcodeproj`, `MyPass/Info.plist`, `MyPassTests/Info.plist`, `.build/`, `Packages/*/.build/`, `/build/`, `/dist/`, `/docs/superpowers/`, `.superpowers/`, `.worktrees/`.

---

# 2. Agent workflow conventions

This repo carries no harness-specific agent config. There is no `.cursor/` directory, no custom agent persona files and no project `.claude/agents/`. Everything an agent needs is in this file, plus whatever skills and subagents the running harness provides globally.

## The orchestrator delegates execution

The main session runs on a deep reasoning model (Opus tier, or Fable as an acceptable alternative) because architectural reasoning, plan synthesis, review judgement and multi-source integration benefit from depth.

Direct writes and edits by that model cost roughly 5x what a mid tier model costs for the same mechanical output. Without discipline the budget burns on work a cheaper model does equally well.

The contract for every session:

> **The orchestrator THINKS, DECIDES, DELEGATES, and VERIFIES.**
> **The orchestrator does NOT write code, run long shell pipelines, or read large file sets directly past the thresholds below.**

The thresholds are HARD numerical triggers, not preferences. When one fires, stop the in-progress tool call and dispatch a subagent instead. No exceptions for "I already have the context" or "it's just one file".

## Two tiers only

| Tier | Who | Model | May dispatch subagents? |
|------|-----|-------|-------------------------|
| **Orchestrator** | Main chat session only | Opus tier, or Fable | **Yes** |
| **Executor, volume** | `general-purpose` for writes and edits, `Explore` for read-only search | `sonnet`, or `haiku` for trivial mechanical work | **No** — execute directly |
| **Executor, judgement** | `Plan` for design work, `general-purpose` with a review prompt for verification | `sonnet` | **No** — execute directly |

**Critical rule:** the hard thresholds below apply **only to the orchestrator tier**. A dispatched subagent is an executor: read, write, edit and shell directly within your prompt scope, and never re-delegate work you were sent to do.

Harnesses name the dispatch tool differently — `Agent(...)` in Claude Code, `Task(...)` in Cursor. The tables below write it as `Agent(...)`.

## HARD RULES — check before every tool call

**Rule 1, writing files**

| File size | Action |
|---|---|
| >30 lines | STOP. Dispatch `Agent(general-purpose, sonnet)`. |
| 10–30 lines, mechanical | Prefer a dispatch. Direct write only when the user is reviewing inline. |
| <10 lines, hand-written | Direct write OK. |

Two or more small files in a row batch into ONE dispatch.

**Rule 2, editing files**

| Edit volume | Action |
|---|---|
| Single edit, <10 lines of diff | Direct edit OK. |
| ≥2 edits, same or multiple files | STOP. Dispatch `Agent(general-purpose, sonnet)` with the full list. |

**Rule 3, reading files**

| Read volume | Action |
|---|---|
| 1–2 files | Direct read OK. |
| ≥3 files for analysis | STOP. Dispatch `Agent(Explore, sonnet)` with the question. |

Exception: the file the user is editing, or the literal subject of the question, is read directly.

**Rule 4, shell context-gathering**

| Command volume | Action |
|---|---|
| 1–2 quick commands | Direct shell OK (`git status`, `ls`, a short `head`). |
| ≥3 commands for context | STOP. Dispatch `Agent(general-purpose, sonnet)` with the batch. |

**Rule 5, self-audit at the start of every response**

Count what the plan implies before issuing any tool call. Writes plus edits ≥2, reads ≥3, context commands ≥3, or any single file over 30 lines — any one of those means the FIRST tool call in the response is the dispatch. No "I'll start and switch later".

## Dispatch templates

```
Agent(subagent_type: "general-purpose", model: "sonnet",
      description: "<3-5 word title>",
      prompt: "<paths, content verbatim or specs, acceptance criteria>")

Agent(subagent_type: "Explore", model: "sonnet",
      description: "<3-5 word title>",
      prompt: "<the question + directory + expected return shape>")

Agent(subagent_type: "Plan", model: "sonnet",
      description: "<3-5 word title>",
      prompt: "<the goal, the constraints, which files matter>")
```

Independent dispatches go out in a single message so they run concurrently.

## What the orchestrator does directly

Read one or two files for high-level reasoning. One or two orientation commands. A single edit of at most ten lines. Plan documents, design conversations and review verdicts in chat. Synthesis of subagent results. Direct dialogue with the user.

## What the orchestrator never does directly

Write a file over 30 lines. Apply two or more edits in one response. Read three or more files for analysis. Run three or more context-gathering commands. Multi-file refactors. Test runs over ten seconds — `./scripts/test.sh` is a full Xcode build plus three `swift test` runs plus every `ChromeExtension/tests/*.test.js` suite, so it always goes to a subagent.

## Not valid reasons to skip a dispatch

| Tempting thought | Reality |
|---|---|
| "It's faster if I do it directly" | A subagent returns in 10–30 seconds. Count the actual seconds. |
| "I already have the context" | Pass it in the prompt. That is what prompts are for. |
| "Just this one file" | Measure it. Over 30 lines? Dispatch. |
| "Simple mechanical edit" | Simple means a cheap model handles it trivially. Dispatch. |
| "The user is waiting" | The user waits longer when the budget burns on mechanical work. |
| "The subagent might miss context" | Pass exact paths and snippets in the prompt. |
| "I'll start and dispatch the rest later" | No. The first tool call is the dispatch. |
| "A hook will catch me if I'm wrong" | A hook is a safety net, not a steering wheel. |

## Skills

Process skills come first and set the approach; implementation skills carry it out.

1. `brainstorming` before any creative or feature work, and before entering plan mode.
2. `systematic-debugging` before proposing a fix for any bug or test failure.
3. `writing-plans` and `executing-plans` for multi-step work. Plans land in `docs/superpowers/plans/`, specs in `docs/superpowers/specs/`; both directories are local-only and gitignored.
4. `verification-before-completion` before claiming anything is done, fixed or passing.
5. `/code-review` and `/security-review` for review passes on a finished branch.

The orchestrator invokes the skill at the right moment. Executors inherit skill instructions through the dispatch prompt and execute directly instead of re-dispatching.

## Cost heuristic

A healthy week shows executor tokens well above orchestrator tokens: executors over 70% of the total, orchestrator under 30%. If the orchestrator share trends above 30%, these rules are being skipped. Pause, re-read this file, dispatch the next chunk.

## Do not use

- `claude-mem` skills (`make-plan`, `do`, `learn-codebase`, `pathfinder`, `smart-explore`). Use the superpowers equivalents. The plugin's cross-session memory stays active; only its skills are off-limits.
- Anything `gsd-*`. Retired tooling, not part of this workflow.

## Anti-patterns

- Sequential dispatches that could have been parallel. Batch them into one message.
- Re-running tools already answered earlier in the session.
- Skipping a review pass. A Sonnet review costs about two cents; a bug caught late costs far more.
- An executor re-dispatching work it was sent to do. Executors do not delegate.
- Claiming work is done without running `./scripts/test.sh` yourself. CI runs unsigned and after the fact, so it is not a substitute.
