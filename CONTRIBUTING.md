# Contributing to MyPass

Thanks for helping. This file is the short version of how to build, test and submit
a change. [`README.md`](README.md) explains what the project is and how the pieces
fit together; [`AGENTS.md`](AGENTS.md) is the instruction file for coding agents
and carries the same project conventions.

## Setup

You need macOS with Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`) and Node.js (for the extension's JavaScript test scripts).
The extension has no build step, `package.json` or bundler, so nothing needs to be
installed for it beyond `node` itself.

`MyPass.xcodeproj` is generated from `project.yml` and gitignored. Regenerate it
with `./scripts/dev.sh generate`; never edit or commit it.

## Commands

| Command | Purpose |
|---|---|
| `./scripts/dev.sh generate` | Create `MyPass.xcodeproj` with XcodeGen. |
| `./scripts/dev.sh build [--unsigned]` | Build `MyPass` and `ChromeHost` into `./build`. |
| `./scripts/dev.sh run` | Quit every running MyPass, build, open the new build. |
| `./scripts/dev.sh install-host [--host PATH] [--install-root DIR]` | Install the native messaging host and manifests. |
| `./scripts/dev.sh package [--out DIR] [--release]` | Build the unsigned development artifacts (a DMG and the extension zip) into `./dist`; `--release` names them for a tagged release. |
| `./scripts/test.sh [--ci] [--no-js]` | Run the app tests, the three package suites and all extension JS suites. |

Load the extension unpacked from `ChromeExtension/` on `chrome://extensions` and
reload it after editing JavaScript. Manual end-to-end fixtures are served with
`python3 -m http.server 8765` from `ChromeExtension/tests/fixtures`; the checklist
is in the second half of [`RUN.md`](RUN.md).

## Tests must really run

Run `./scripts/test.sh` before you say a change is done, and show real results in
your pull request. The tests are not allowed to be skipped, weakened or deleted to
make something pass.

- `--no-js` exists only for a local machine without `node`, and it prints that the
  JavaScript suites were **not** run. A change that touches `ChromeExtension/` needs
  them run.
- `--ci` is the unsigned mode used by the CI workflow. It rejects `--no-js` and
  requires every tool. A green unsigned run proves logic, not the runtime behaviour
  of a signed build (Touch ID, Keychain access groups).
- A GitHub Actions workflow (`.github/workflows/ci.yml`) runs on pull requests, on
  pushes to `master` and on manual dispatch. It is unsigned and reports after the
  fact, so it is not a substitute for running the suite yourself.
- `.github/workflows/codeql.yml` runs CodeQL on the same triggers plus a weekly
  schedule. `.coderabbit.yaml` configures CodeRabbit pull request reviews, which run
  only while the CodeRabbit GitHub App is installed; if no review starts, comment
  `@coderabbitai review`. Neither result blocks a merge by itself: that is set in the
  repository's GitHub branch protection, not in these files.
- New behaviour comes with tests next to the code it covers. The suite has no
  linter or formatter, so match the style of the surrounding code by hand.

Signing note: the project pins a stable `DEVELOPMENT_TEAM` in `project.yml`
because ad-hoc signing breaks the Keychain ACL that guards the biometric unlock key.
Do not switch it to ad-hoc, and do not edit `project.yml` to build with your own
Team (see "Signing" in the README for a command-line override).

## Language

Everything is English: code, comments, commit messages, UI strings, extension copy,
docs, plans, specs and error messages. The one exception is root `RUN.md`, which is
Ukrainian and must not be translated. Runtime localization is deferred, so ship
English strings. Test data and rule heuristics may contain non-English text.

## Commits and pull requests

Commits follow Conventional Commits with a scope, a lowercase imperative subject and
no trailing period, for example:

```text
fix(app): reset auto-lock idle timer on deliberate extension activity
```

Scopes in use: `app`, `extension`, `chrome`, `scripts`, `entry-edit`, plus `ci` for
the workflow and `docs` for documentation-only changes.

Keep a pull request to one concern. Comments that record why a constraint exists
(signing, libsodium salt length, queue choices) are a feature of this code base;
preserve them when editing. `docs/implementation/ROADMAP.md` lists only work that
is still open: remove an item once it is implemented and its tests pass. Design notes and plans are local working files
(`docs/superpowers/` is gitignored); do not commit them, and put anything
contributors need to know in the README, this file or the code comments.

Do not commit the generated or local files listed in `.gitignore`
(`*.xcodeproj`, `MyPass/Info.plist`, `MyPassTests/Info.plist`, `.build/`, `build/`,
`dist/`, `docs/superpowers/`, `.worktrees/` and similar), vault files with real data, or secrets.

## Dependencies and the notices checklist

Adding, removing or upgrading a dependency, or re-vendoring a file, changes what
the build artifacts contain. In the same pull request:

- [ ] Update [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md): component name,
      version and commit, license, where it lives, and the upstream license text
      copied verbatim, plus the upstream `NOTICE` content when the license (for
      example Apache-2.0 section 4(d)) requires it.
- [ ] Check transitive dependencies in the resolved `Package.resolved` files and
      against the targets the app really links; the notices file is a reviewed
      list, not generated from `Package.resolved`.
- [ ] For a vendored file, update its provenance file (`VENDORING.md` or
      `PASSWORD_RULES_PROVENANCE.md`) with the upstream URL and commit.
- [ ] Confirm the license is compatible with an Apache-2.0 project.

## Security

Do not put passwords, vault files, master keys, tokens or key material in an issue,
a pull request or a log you attach. Do not describe a security vulnerability in
detail in a public issue or pull request. Report vulnerabilities as described in
[`SECURITY.md`](SECURITY.md).

## License

Under section 5 of the Apache License 2.0, a contribution you submit for inclusion
is licensed under that license unless you state otherwise (see
[`LICENSE`](LICENSE)).
