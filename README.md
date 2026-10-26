# MyPass

MyPass is a native macOS password manager built on the KeePass **KDBX4** vault
format, paired with a Chromium browser extension for autofill, TOTP and
WebAuthn passkeys.

| Component | Stack |
|---|---|
| macOS app | Swift + SwiftUI, macOS 14.0+ |
| Native messaging host (`ChromeHost`) | Swift command-line tool that relays between the browser and the app |
| Browser extension | Plain JavaScript, Manifest V3, no bundler, Chrome 127+ |

Vaults are standard KDBX4 files. Sync backends are SFTP, iCloud Drive and a local
folder, merged with a three-way merge. Autofill, TOTP and passkeys work through the
extension; the app unlocks with the master password and, on a signed build, with
Touch ID.

## Read this first: development builds only

MyPass is pre-release software (version 0.2.0). There is **no notarized or
Developer ID signed release and no Chrome Web Store listing**. What the project
can give you today is source you build yourself, plus unsigned **development
artifacts** (built locally by `./scripts/dev.sh package`, and attached to runs of the
CI workflow). Tagged GitHub releases exist as of the first release, but they are
equally unsigned and not notarized: the warning below applies to them in full.

- Do not treat the unsigned artifacts as a way to run a real password vault. They
  are for development and inspection. They are built without a signing identity and
  without the app's entitlements, so macOS features that depend on them (Touch ID
  unlock, and the Keychain-backed token exchange between the app and `ChromeHost`)
  are expected to be limited or non-functional. This has **not been tested**; the
  builds are not claimed to work for those paths.
- The supported way to run MyPass, including Touch ID and the browser bridge, is a
  locally built app signed with a stable signing identity (see below).
- Keep backups of any vault you open with a development build. No independent
  security review of MyPass is claimed.
- The GitHub Actions workflow in `.github/workflows/ci.yml` runs the full test suite
  and packages the development artifacts on pull requests, on pushes to `master` and
  on manual dispatch. It builds unsigned on arm64, so a green run is evidence about
  logic only. Check the Actions tab for the actual result of any given run.

## Installing a release

Tagged releases are published at <https://github.com/slucheninov/mypass/releases>.
Each one carries three downloads:

- `MyPass-X.Y.Z-macos-arm64.dmg`: the app, `ChromeHost` and the install helper.
- `MyPass-chrome-extension-X.Y.Z.zip`: the browser extension (sideload package).
- `SHA256SUMS.txt`: checksums for the two files above (`shasum -a 256 -c SHA256SUMS.txt`).

The release is unsigned and not notarized, so read the warning above first. In short:

1. Before opening the DMG, clear its quarantine flag:
   `xattr -d com.apple.quarantine ~/Downloads/MyPass-X.Y.Z-macos-arm64.dmg`.
2. Open the DMG and drag `MyPass.app` onto the `Applications` shortcut, then run it
   from `/Applications`.
3. On first launch macOS may show Keychain prompts; choose "Always Allow" for the
   MyPass items.
4. With the DMG still mounted, run
   `"/Volumes/MyPass X.Y.Z/dev.sh" install-host` to install the native messaging host.
5. Unzip the extension, open `chrome://extensions`, enable Developer mode, choose
   "Load unpacked" and select the folder, then pair it from the app.
6. To update, repeat the steps with the new release.

`INSTALL.txt` inside the DMG has the details, including removal.

## Building from source

Requirements: macOS with Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`), and Node.js to run the extension's JavaScript test
suites.

There are three maintained scripts under `scripts/` (`dev.sh`, `test.sh` and
`update-password-rules.sh`):

| Command | What it does |
|---|---|
| `./scripts/dev.sh generate` | Run XcodeGen to create `MyPass.xcodeproj` (generated, gitignored, never edit it). |
| `./scripts/dev.sh build [--unsigned]` | Generate the project, then build `MyPass` and `ChromeHost` into `./build`. Without the flag the build uses the stable team signing from `project.yml`; `--unsigned` builds with no signing and no entitlements. |
| `./scripts/dev.sh run` | Ask every running MyPass to quit and wait up to 15 s for it to exit, then build, then open the new build and check that it is the only MyPass running. A copy that will not quit stops the run before the build; nothing is force-killed. |
| `./scripts/dev.sh set-version X.Y.Z` | Set the app, host and extension version together (`project.yml` twice, `ChromeExtension/manifest.json`). Plain `X.Y.Z` only; it does not commit. |
| `./scripts/dev.sh install-host [--host PATH] [--install-root DIR]` | Install the native messaging host and browser manifests (see below). |
| `./scripts/dev.sh package [--out DIR] [--release]` | Build Release for arm64, seal it ad hoc, and write the macOS DMG and the Chrome extension zip into `./dist` (or `DIR`); `--release` is for tagged releases (see Cutting a release). |
| `./scripts/test.sh [--ci] [--no-js]` | Run the Xcode app tests, the three Swift package test suites and every `ChromeExtension/tests/*.test.js` suite. |
| `./scripts/update-password-rules.sh` | Refresh the vendored Apple password-rules snapshot and its provenance file. |

`scripts/test.sh` needs `node` for the JavaScript suites. Without it a local run
fails; `--no-js` skips them and prints that they were **not** run. `--ci` rejects
`--no-js`, requires every tool, and builds without code signing through
command-line overrides only (`project.yml` is untouched). Passing tests prove
logic, not the runtime security behaviour of a signed build.

### Launching while MyPass is already running

Only one MyPass owns the vault and the browser bridge. A newer launch asks the
running one to hand over; the older copy saves through its normal quit path and
exits, and the newest launch wins. If the save fails or does not finish, the
older copy asks **Cancel** or **Quit Anyway**; the newer launch waits up to 15 s,
then refuses to start and tells you why (it never opens the vault alongside
another copy). A build from before this guard has no
listener, so the new launch refuses to start: quit that copy manually, or use
`./scripts/dev.sh run`, which quits every running copy before it builds. Hosted
test runs and SwiftUI previews skip the check, so they never make a running MyPass
quit.

Opt-in integration tests: `MYPASS_KEYCHAIN_TESTS=1`,
`MYPASS_SFTP_INTEGRATION_TESTS=1` (needs the Docker fixture in
`Packages/SyncKit/Tests/Fixtures/docker-sshd`, whose throwaway SSH keys are
generated by its `run.sh` and git-ignored), `MYPASS_ICLOUD_INTEGRATION_TESTS=1`.

### Signing

`project.yml` pins `DEVELOPMENT_TEAM`. A stable signing identity is required for
the app, not a convenience: ad-hoc signing changes the code-directory hash on every
build, which silently breaks the Keychain ACL that guards the biometric unlock key.
That is why the default `dev.sh build` keeps team signing and the unsigned paths
exist only behind explicit flags (`--unsigned`, `--ci`, `package`).

If you build with your own Apple developer Team, do not edit `project.yml`.
Generate the project with `./scripts/dev.sh generate`, then pass your Team on the
`xcodebuild` command line, which takes precedence over the project setting:

```sh
xcodebuild -project MyPass.xcodeproj -scheme MyPass -configuration Debug \
  -derivedDataPath build DEVELOPMENT_TEAM=<YOUR_TEAM_ID> build
```

Passing a Team is not enough on its own, and nothing here promises that it works. The
bundle identifiers (`com.mypass.app`, `com.mypass.chromehost`) and the entitlements
(App Sandbox, network, and the Keychain access groups `com.mypass.app.keychain`,
`.pairing` and `.biometric`, listed in `MyPass/MyPass.entitlements` and
`ChromeHost/ChromeHost.entitlements`) are fixed in `project.yml` and the entitlements
files. Automatic signing under your own Team may be unable to provision those
identifiers and groups, in which case you would need your own bundle identifiers,
provisioning and entitlements (local edits you must not commit). Changing the
entitlements or Keychain groups changes what the Touch ID unlock and the app-to-host
token exchange can reach, so they must stay consistent between the app and
`ChromeHost`. A different Team also gives the app a different signing identity, so
Keychain items and the biometric key from a build made with another identity are not
shared. This route is not covered by the project's tests and is untested: it is not a
supported configuration.

### Cutting a release

```sh
./scripts/dev.sh set-version X.Y.Z
git commit -am "chore(release): bump version to X.Y.Z"
git tag vX.Y.Z
git push origin master vX.Y.Z
```

Watch the Release workflow in the Actions tab; the release appears as a draft and is
published after its assets are verified. A failed run is fixed forward with the next
patch tag; a pushed tag is never moved or deleted.

## The browser extension and the native messaging host

The extension lives in `ChromeExtension/` and has no build step. Load it unpacked on
`chrome://extensions` (Developer mode, "Load unpacked") and reload it there after
editing JavaScript. Its ID is pinned to `hjijbabodfldconmhdcdphlbgaajkejn` by the
public `key` in `manifest.json`.

The extension talks to the app through `ChromeHost`, using Chrome native messaging.
Install the host once per machine, after `ChromeHost` has been built:

```sh
./scripts/dev.sh build
./scripts/dev.sh install-host
```

`install-host` copies `ChromeHost` to
`~/Library/Application Support/MyPass/ChromeHost` and writes
`com.mypass.chromehost.json` into the `NativeMessagingHosts` directory of every
installed Chromium-family browser it knows (Chrome and Chrome for Testing always,
the others only when their directory already exists). The manifest allows only the
pinned extension ID. The host binary is taken from `--host PATH`, else from
`ChromeHost` next to the script, else from the `./build` tree of a checkout. The
destination root is `--install-root DIR`, else `MYPASS_INSTALL_ROOT`, else `$HOME`;
`HOME` itself is never changed. The command needs no Xcode and no `python3`, writes
only `ChromeHost` and the manifests, refuses to overwrite through a symlink or when
source and destination are the same file, and never deletes anything. Remove the host
and manifests by hand to uninstall.

After the host is installed, pair a browser: open the extension popup, choose
**Connect to MyPass**, and enter the 6-digit code shown in the app (valid for 120
seconds). Pairings are revocable in the app's Settings, Browser tab.

## Development artifacts

`./scripts/dev.sh package` (and each CI run, which uploads them as artifacts kept for
14 days) produces a DMG and a zip, named with the version and the short commit SHA (a
`-dirty` suffix marks a dirty working tree, `nogit` a build outside a git checkout):

- `MyPass-<version>-macos-arm64-<sha7>.dmg`: a volume with `MyPass.app`, an
  `Applications` shortcut, `ChromeHost`, `dev.sh` (only `install-host` is meant to be
  used), `INSTALL.txt`, `LICENSE` and `THIRD_PARTY_NOTICES.md`. `INSTALL.txt` states the
  development-only warning, how to clear the download quarantine flag, how to run
  `dev.sh install-host`, and how to remove the host and manifests by hand.
- `MyPass-chrome-extension-<version>-<sha7>.zip`: the extension's runtime files with
  `manifest.json` at the zip root, plus `LICENSE` and `THIRD_PARTY_NOTICES.md`. The
  tests are excluded. It is a sideload package, not a Web Store submission.

The macOS build is arm64 only (macOS 14.0 deployment target).

## Repository layout

| Path | Contents |
|---|---|
| `MyPass/` | The SwiftUI app. |
| `ChromeHost/` | The native messaging host. |
| `ChromeExtension/` | The browser extension and its plain-node test scripts. |
| `Packages/MyPassKit/` | KDBX4 engine, TOTP and password generators, Public Suffix List. |
| `Packages/SyncKit/` | SFTP, iCloud Drive and local folder backends, merge and sync engine. |
| `Packages/ExtensionBridgeKit/` | Shared app-to-host protocol. |
| `docs/` | `docs/implementation/ROADMAP.md`: the work that is still open. |
| `RUN.md` | Run and manual verification checklist, in Ukrainian. |

## Dependencies

Third-party code and the notices it requires are listed in
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md). One dependency is worth a
note: SFTP sync uses [Citadel](https://github.com/orlandos-nl/Citadel), which
depends on a fork of Apple's NIOSSH, [`Wellz26/swift-nio-ssh`](https://github.com/Wellz26/swift-nio-ssh).
`Packages/SyncKit/Package.swift` names the same fork and version range as Citadel
0.12.1 so that SwiftPM resolves a single `swift-nio-ssh`. The fork describes itself
as "A fork of Apple's NIOSSH, to be archived once Apple reviews and merges 2 year
old PRs". Replacing it is out of scope for now.

## Contributing and license

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the commands, the commit convention and
the review checklist.

MyPass is released under the [Apache License 2.0](LICENSE).
