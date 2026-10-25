#!/usr/bin/env bash
# Run every test suite: the app (xcodebuild), the three Swift packages, and all
# ChromeExtension/tests/*.test.js scripts.
#
#   scripts/test.sh              local run, stable team signing from project.yml
#   scripts/test.sh --no-js      local run that explicitly skips the JS suites (loudly)
#   scripts/test.sh --ci         unsigned run for CI; every tool and every suite is required
#
# Opt-in integration suites keep their environment switches (MYPASS_KEYCHAIN_TESTS=1,
# MYPASS_SFTP_INTEGRATION_TESTS=1, MYPASS_ICLOUD_INTEGRATION_TESTS=1).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

usage() {
  echo "Usage: scripts/test.sh [--ci] [--no-js]" >&2
  echo "  --ci     unsigned build overrides, arm64, every tool and suite required" >&2
  echo "  --no-js  local only: skip the JS suites (prints a loud warning; rejected with --ci)" >&2
}

# Task-scoped on purpose: a bare `CI` variable here would shadow the CI=true that GitHub Actions
# exports to every child process (xcodebuild, swift, node), so the inherited value is left alone.
CI_MODE=0
NO_JS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ci) CI_MODE=1 ;;
    --no-js) NO_JS=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Error: unknown option: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

if (( CI_MODE && NO_JS )); then
  echo "Error: --ci runs every suite; it cannot be combined with --no-js." >&2
  exit 2
fi

require_command() {
  local cmd="$1"
  local hint="${2:-}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: required command '$cmd' not found." >&2
    [[ -n "$hint" ]] && echo "$hint" >&2
    exit 1
  fi
}

require_command xcodebuild "Install Xcode from the App Store."
require_command swift "Install Xcode from the App Store."
require_command xcodegen "Install with: brew install xcodegen"
if (( CI_MODE )); then
  require_command node "--ci runs every suite, including the JS ones: install Node.js."
elif (( ! NO_JS )); then
  require_command node "Install Node.js, or pass --no-js to skip the JS suites explicitly (they are then reported as NOT run)."
fi

if (( CI_MODE )); then
  echo "== CI mode: unsigned, arm64 =="
  xcodebuild -version
  swift --version
  node --version
fi

# Stages run to completion and failures are collected, so one broken suite does not hide
# the state of the others. The script exits non-zero if any stage failed.
FAILED_STAGES=()

run_stage() {
  local name="$1"
  shift
  echo
  echo "== $name =="
  if "$@"; then
    echo "== $name: passed =="
  else
    echo "== $name: FAILED ==" >&2
    FAILED_STAGES+=("$name")
  fi
}

"$ROOT/scripts/dev.sh" generate

# Dependencies resolve only to the committed pins that `generate` seeded into the workspace
# (see dev.sh, "Swift package lock"); Xcode fails instead of picking newer versions. The
# package suites get the same guarantee from SwiftPM with each package's own Package.resolved.
RESOLVED_ONLY=(-onlyUsePackageVersionsFromResolvedFile)

if (( CI_MODE )); then
  # Overrides exist only on the command line; project.yml keeps the stable team signing
  # (ad-hoc signing there would break the biometric Keychain ACL). A separate derived
  # data path keeps this run from touching the signed dev build under build/dev.
  CI_SETTINGS=(CODE_SIGNING_ALLOWED=NO CODE_SIGN_ENTITLEMENTS= ARCHS=arm64 ONLY_ACTIVE_ARCH=NO)
  CI_DESTINATION='platform=macOS,arch=arm64'
  CI_DERIVED="$ROOT/build/ci"
  CI_PACKAGES="$ROOT/build/SourcePackages"
  run_stage "MyPass app tests" \
    xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination "$CI_DESTINATION" \
      -derivedDataPath "$CI_DERIVED" -clonedSourcePackagesDirPath "$CI_PACKAGES" "${RESOLVED_ONLY[@]}" "${CI_SETTINGS[@]}"
  run_stage "ChromeHost build" \
    xcodebuild build -project MyPass.xcodeproj -scheme ChromeHost -destination "$CI_DESTINATION" \
      -derivedDataPath "$CI_DERIVED" -clonedSourcePackagesDirPath "$CI_PACKAGES" "${RESOLVED_ONLY[@]}" "${CI_SETTINGS[@]}"
else
  run_stage "MyPass app tests" \
    xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' "${RESOLVED_ONLY[@]}"
fi

package_tests() {
  (cd "$ROOT/Packages/$1" && swift test --only-use-versions-from-resolved-file)
}
run_stage "MyPassKit tests" package_tests MyPassKit
run_stage "SyncKit tests" package_tests SyncKit
run_stage "ExtensionBridgeKit tests" package_tests ExtensionBridgeKit

JS_RAN=0
JS_FAILED=()
if (( NO_JS )); then
  echo
  echo "!! JS suites NOT run (--no-js). This run does not cover ChromeExtension/tests. !!" >&2
else
  # Each suite is a plain node script in its own process. Glob order is made stable with
  # LC_ALL=C; an empty match is an error, not a pass (a moved directory must not turn the
  # JS tests silently green).
  JS_SUITES=()
  while IFS= read -r suite; do
    JS_SUITES+=("$suite")
  done < <(LC_ALL=C find ChromeExtension/tests -maxdepth 1 -type f -name '*.test.js' | LC_ALL=C sort)

  echo
  echo "== ChromeExtension JS suites (${#JS_SUITES[@]} found) =="
  if [[ ${#JS_SUITES[@]} -eq 0 ]]; then
    echo "Error: no ChromeExtension/tests/*.test.js suites found." >&2
    FAILED_STAGES+=("JS suites (none found)")
  else
    for suite in "${JS_SUITES[@]}"; do
      JS_RAN=$(( JS_RAN + 1 ))
      echo "-- node $suite"
      if ! node "$suite"; then
        echo "-- FAILED: $suite" >&2
        JS_FAILED+=("$suite")
      fi
    done
    echo "== JS suites: $JS_RAN run, ${#JS_FAILED[@]} failed =="
    if [[ ${#JS_FAILED[@]} -gt 0 ]]; then
      FAILED_STAGES+=("JS suites")
    fi
  fi
fi

echo
echo "== Summary =="
if (( NO_JS )); then
  echo "!! JS suites NOT run (--no-js) !!" >&2
fi
if [[ ${#JS_FAILED[@]} -gt 0 ]]; then
  echo "Failed JS suites:" >&2
  for suite in "${JS_FAILED[@]}"; do
    echo "  $suite" >&2
  done
fi
if [[ ${#FAILED_STAGES[@]} -gt 0 ]]; then
  echo "FAILED stages:" >&2
  for stage in "${FAILED_STAGES[@]}"; do
    echo "  $stage" >&2
  done
  exit 1
fi
echo "All requested stages passed."
