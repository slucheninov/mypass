#!/usr/bin/env bash
# Single developer entry point: generate the Xcode project, build, run, install the
# native messaging host, and package unsigned development artifacts.
#
#   scripts/dev.sh generate
#   scripts/dev.sh build   [--unsigned]
#   scripts/dev.sh run
#   scripts/dev.sh install-host [--host PATH] [--install-root DIR]
#   scripts/dev.sh package [--out DIR] [--release]
#
# This same file ships inside the macOS artifact, where it must keep working with no
# source tree, no Xcode and no python3. Only `install-host` is meant to be used there,
# so it depends on nothing but the macOS base system, and nothing at the top level may
# assume a checkout (see require_checkout).
set -euo pipefail

# Follow symlinks to the script's real location without realpath(1) (absent before
# macOS 13) or python3. ChromeHost is looked up next to the *real* script, so a symlink
# to dev.sh from some other directory still finds the host that shipped with it.
resolve_script_path() {
  local src="$1" dir target
  while [[ -L "$src" ]]; do
    dir="$(cd -P "$(dirname "$src")" && pwd)"
    target="$(readlink "$src")"
    case "$target" in
      /*) src="$target" ;;
      *) src="$dir/$target" ;;
    esac
  done
  dir="$(cd -P "$(dirname "$src")" && pwd)"
  printf '%s/%s\n' "$dir" "$(basename "$src")"
}

SCRIPT_PATH="$(resolve_script_path "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

# REPO_ROOT stays empty when this copy of dev.sh was extracted from an artifact.
REPO_ROOT=""
if [[ "$(basename "$SCRIPT_DIR")" == "scripts" && -f "$SCRIPT_DIR/../project.yml" ]]; then
  REPO_ROOT="$(cd -P "$SCRIPT_DIR/.." && pwd)"
fi

BUNDLE_ID="com.mypass.app"
EXTENSION_ID="hjijbabodfldconmhdcdphlbgaajkejn"
HOST_NAME="com.mypass.chromehost"

# Chromium-family browsers whose native messaging manifests we install. Google Chrome and
# Chrome for Testing are always written (their profile directory may not exist yet); the
# others only when their base directory already exists.
CHROMIUM_BROWSER_BASES=(
  "Google/Chrome"
  "Google/Chrome for Testing"
  "Google/Chrome Beta"
  "Google/Chrome Canary"
  "Google/Chrome Dev"
  "Chromium"
  "Microsoft Edge"
  "Microsoft Edge Beta"
  "Microsoft Edge Dev"
  "Microsoft Edge Canary"
  "BraveSoftware/Brave-Browser"
  "BraveSoftware/Brave-Browser-Beta"
  "BraveSoftware/Brave-Browser-Nightly"
  "Vivaldi"
  "Vivaldi Snapshot"
  "com.operasoftware.Opera"
  "com.operasoftware.OperaGX"
  "Arc/User Data"
)

usage() {
  cat <<'EOF'
Usage: scripts/dev.sh <command> [options]

Commands (checkout only, need Xcode and xcodegen):
  generate                   Regenerate MyPass.xcodeproj with xcodegen, then seed its Swift
                             package lock from the committed Packages/SyncKit/Package.resolved
                             (fails if the committed locks disagree). Builds then use only
                             those pins.
  build [--unsigned]         Generate, then build MyPass and ChromeHost into ./build.
                             Default: Debug with the stable team signing from project.yml.
                             --unsigned: no code signing and no entitlements (separate
                             output directory, never mixed with the signed build).
  run                        Check tools and package locks, politely quit EVERY running
                             MyPass copy (com.mypass.app, whichever path it runs from) and
                             wait up to 15 s for each to exit, THEN build (signed), open the
                             new build with `open -n` and verify that exactly one MyPass is
                             running and it is the executable just built. If a copy will not
                             quit, nothing is built; if the build fails, no MyPass is left
                             running. Nothing is force-killed and no MyPass.app is removed.
  package [--out DIR] [--release]
                             Build Release for arm64 without signing, seal it ad hoc, and
                             write the macOS DMG and the Chrome extension zip into DIR
                             (default ./dist). Development artifacts only.
                             --release: requires a clean working tree and HEAD exactly at
                             tag vX.Y.Z matching the project version; drops the commit
                             suffix from the file names and writes SHA256SUMS.txt.
  set-version X.Y.Z          Set the app, host and extension version together (project.yml x2,
                             ChromeExtension/manifest.json). Plain X.Y.Z only. Does not commit.

Command available from an extracted artifact as well (macOS base tools only):
  install-host [--host PATH] [--install-root DIR]
                             Copy ChromeHost under <root>/Library/Application Support/MyPass
                             and write a native messaging manifest for every installed
                             Chromium-family browser.
                             Host:  --host, else ChromeHost next to this script, else the
                                    first build found in a checkout (build/dev, then
                                    build/dev-unsigned, then build/package).
                                    The chosen host and its signing are printed, other
                                    builds found are listed, and a team-signed installed
                                    host is never replaced by a less-signed host chosen
                                    this way: pass --host to do that on purpose.
                             Root:  --install-root, else $MYPASS_INSTALL_ROOT, else $HOME.
                                    HOME and the environment are never modified.

Exit status: 0 success, 1 failure, 2 usage error.
EOF
}

usage_error() {
  echo "Error: $*" >&2
  echo >&2
  usage >&2
  exit 2
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

require_command() {
  local cmd="$1"
  local hint="${2:-}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: required command '$cmd' not found." >&2
    [[ -n "$hint" ]] && echo "$hint" >&2
    exit 1
  fi
}

require_checkout() {
  [[ -n "$REPO_ROOT" ]] || fail "'$1' needs a source checkout; this copy of dev.sh is not inside one."
}

# --- cleanup -----------------------------------------------------------------------------
# The EXIT trap removes only what this process created: temp files from `mktemp` next to
# an install destination, and the single staging directory `package` makes inside --out.
OWNED_TMP_FILES=()
OWNED_STAGE_DIR=""
OWNED_STAGE_PARENT=""

cleanup() {
  local rc=$? f
  # `run` quits MyPass before it builds. If the build then dies, say so plainly: the old app
  # is not running and is deliberately not relaunched (it would be stale).
  if [[ "${RUN_BUILD_IN_PROGRESS:-0}" == "1" && $rc -ne 0 ]]; then
    echo "Error: the build failed after MyPass was quit. No MyPass is running, and the previous app was not relaunched." >&2
  fi
  for f in ${OWNED_TMP_FILES[@]+"${OWNED_TMP_FILES[@]}"}; do
    if [[ -n "$f" && -f "$f" && ! -L "$f" ]]; then
      rm -f -- "$f"
    fi
  done
  if [[ -n "$OWNED_STAGE_DIR" && -d "$OWNED_STAGE_DIR" && ! -L "$OWNED_STAGE_DIR" ]]; then
    case "$OWNED_STAGE_DIR" in
      "$OWNED_STAGE_PARENT"/.package-stage.*) rm -rf -- "$OWNED_STAGE_DIR" ;;
    esac
  fi
}
trap cleanup EXIT
# Turn Ctrl-C / SIGTERM into a normal exit so the EXIT trap above always runs.
trap 'exit 130' INT
trap 'exit 143' TERM

# --- generate / build / run ----------------------------------------------------------------

# --- Swift package lock --------------------------------------------------------------------
#
# Xcode resolves the remote dependencies of the three local packages at workspace level.
# The generated project (gitignored, rebuilt by xcodegen) starts with no Package.resolved,
# so left alone Xcode picks the newest allowed versions and a clean checkout would not build
# the dependency graph the committed locks describe. The committed locks are the source of
# truth:
#
#   Packages/SyncKit/Package.resolved    superset: SyncKit depends on MyPassKit, so it pins
#                                        every remote package the app links (MyPassKit's
#                                        swift-sodium plus Citadel and its graph)
#   Packages/MyPassKit/Package.resolved  must be a subset of the superset, pin for pin
#   Packages/ExtensionBridgeKit          has no remote dependencies and therefore no lock
#
# `generate` seeds the workspace lock from the superset after xcodegen ran, and every
# xcodebuild call passes -onlyUsePackageVersionsFromResolvedFile so Xcode may not move a
# pin. No pin is ever invented here: a disagreement is a hard error, never a merge.
PACKAGE_LOCK_SOURCE_REL="Packages/SyncKit/Package.resolved"
PACKAGE_LOCK_AGREE_RELS=("Packages/MyPassKit/Package.resolved")
PACKAGE_MANIFEST_RELS=("Packages/MyPassKit/Package.swift" "Packages/SyncKit/Package.swift" "Packages/ExtensionBridgeKit/Package.swift")
WORKSPACE_LOCK_REL="MyPass.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

# lock_pins FILE: one sorted "identity|kind|location|revision|version|branch" line per pin.
# Parsed with awk because the file is machine-written with one key per line, and this must
# not need python or jq. A pin that is not an exact version at a revision shows up with an
# empty field and is rejected by package_lock_check_source.
lock_pins() {
  awk '
    function value(line,   s) {
      if (!match(line, /:[[:space:]]*"[^"]*"/)) return ""
      s = substr(line, RSTART, RLENGTH)
      sub(/^:[[:space:]]*"/, "", s)
      sub(/"$/, "", s)
      return s
    }
    function flush() {
      if (id != "") print id "|" kind "|" loc "|" rev "|" ver "|" br
      id = kind = loc = rev = ver = br = ""
    }
    /"identity"[[:space:]]*:/ { flush(); id = value($0) }
    /"kind"[[:space:]]*:/ { kind = value($0) }
    /"location"[[:space:]]*:/ { loc = value($0) }
    /"revision"[[:space:]]*:/ { rev = value($0) }
    /"version"[[:space:]]*:[[:space:]]*"/ { ver = value($0) }
    /"branch"[[:space:]]*:/ { br = value($0) }
    END { flush() }
  ' "$1" | LC_ALL=C sort
}

# The superset must exist, be format 3, and pin every package to an exact version at a full
# revision (a branch or revision-only pin floats).
package_lock_check_source() {
  local src="$REPO_ROOT/$PACKAGE_LOCK_SOURCE_REL" pins line
  [[ -f "$src" ]] || fail "$PACKAGE_LOCK_SOURCE_REL is missing. It is the committed lock that pins every Swift package dependency; restore it from git."
  grep -Eq '"version"[[:space:]]*:[[:space:]]*3[[:space:]]*$' "$src" \
    || fail "$PACKAGE_LOCK_SOURCE_REL is not a Package.resolved format 3 file; refusing to seed the Xcode workspace from it."
  pins="$(lock_pins "$src")"
  [[ -n "$pins" ]] || fail "$PACKAGE_LOCK_SOURCE_REL contains no pins."
  while IFS= read -r line; do
    case "$line" in
      *\|remoteSourceControl\|https://*\|????????????????????????????????????????\|?*\|) ;;
      *) fail "$PACKAGE_LOCK_SOURCE_REL has a pin that is not an exact version at a full revision (a branch or revision-only pin floats): $line" ;;
    esac
  done <<EOF
$pins
EOF
}

# Every other committed lock must be a subset of the superset, and every remote dependency a
# Package.swift declares by URL must be pinned in the superset.
package_lock_check_agreement() {
  local src="$REPO_ROOT/$PACKAGE_LOCK_SOURCE_REL" rel other_pins src_pins extra manifest url
  src_pins="$(lock_pins "$src")"
  for rel in ${PACKAGE_LOCK_AGREE_RELS[@]+"${PACKAGE_LOCK_AGREE_RELS[@]}"}; do
    [[ -f "$REPO_ROOT/$rel" ]] || fail "$rel is missing; it must agree with $PACKAGE_LOCK_SOURCE_REL."
    other_pins="$(lock_pins "$REPO_ROOT/$rel")"
    extra="$(comm -23 <(printf '%s\n' "$other_pins") <(printf '%s\n' "$src_pins"))"
    if [[ -n "$extra" ]]; then
      echo "Error: $rel disagrees with $PACKAGE_LOCK_SOURCE_REL; these pins are absent from it or differ in version or revision:" >&2
      printf '  %s\n' "$extra" >&2
      echo "Make the committed locks agree before building (nothing was changed)." >&2
      exit 1
    fi
  done
  for manifest in "${PACKAGE_MANIFEST_RELS[@]}"; do
    [[ -f "$REPO_ROOT/$manifest" ]] || fail "$manifest is missing."
    while IFS= read -r url; do
      [[ -n "$url" ]] || continue
      if ! grep -qF "|$url|" <<<"$src_pins"; then
        fail "$manifest depends on $url, which has no pin in $PACKAGE_LOCK_SOURCE_REL. Resolve it and commit the lock; the build refuses to float."
      fi
    done <<EOF
$(sed -nE 's/^[[:space:]]*\.package\(url:[[:space:]]*"([^"]+)".*/\1/p' "$REPO_ROOT/$manifest")
EOF
  done
}

# Copy the superset into the generated workspace. A workspace lock holding other pins is
# generated state left by an earlier floating resolution; it is replaced (and that is said)
# rather than trusted.
seed_package_lock() {
  local src="$REPO_ROOT/$PACKAGE_LOCK_SOURCE_REL" dest="$REPO_ROOT/$WORKSPACE_LOCK_REL" tmp
  package_lock_check_source
  package_lock_check_agreement
  [[ -d "$REPO_ROOT/MyPass.xcodeproj" ]] || fail "MyPass.xcodeproj was not generated."
  mkdir -p -- "$(dirname "$dest")"
  if [[ -f "$dest" && "$(lock_pins "$dest")" != "$(lock_pins "$src")" ]]; then
    echo "Note: replacing the workspace Package.resolved with the pins from $PACKAGE_LOCK_SOURCE_REL (it held different pins)." >&2
  fi
  tmp="$(mktemp "$(dirname "$dest")/.Package.resolved.XXXXXX")" || fail "could not create a temporary file next to $WORKSPACE_LOCK_REL."
  OWNED_TMP_FILES+=("$tmp")
  cp -- "$src" "$tmp"
  chmod 644 "$tmp"
  mv -f -- "$tmp" "$dest"
}

# After Xcode ran the workspace lock must still hold exactly the committed pins. The flag
# already stops Xcode from moving them; this catches anything else that rewrote the file.
verify_package_lock() {
  local src="$REPO_ROOT/$PACKAGE_LOCK_SOURCE_REL" dest="$REPO_ROOT/$WORKSPACE_LOCK_REL"
  [[ -f "$dest" ]] || fail "$WORKSPACE_LOCK_REL disappeared during the build."
  [[ "$(lock_pins "$dest")" == "$(lock_pins "$src")" ]] \
    || fail "the Xcode workspace Package.resolved no longer matches $PACKAGE_LOCK_SOURCE_REL after the build; dependency pins drifted."
}

cmd_generate() {
  [[ $# -eq 0 ]] || usage_error "'generate' takes no arguments."
  require_checkout generate
  require_command xcodegen "Install with: brew install xcodegen"
  # Validate the committed locks first so a conflict fails before anything is regenerated.
  package_lock_check_source
  package_lock_check_agreement
  (cd "$REPO_ROOT" && xcodegen generate)
  seed_package_lock
}

# xcode_build FLAVOR CONFIGURATION SCHEME DESTINATION [build setting or flag ...]
# Each flavor has its own -derivedDataPath under build/, so a signed dev build, an unsigned
# dev build and the Release package never overwrite each other. Swift package checkouts are
# shared so the three flavors do not each re-clone every dependency. Packages resolve only
# to the pins seeded by `generate`; -onlyUsePackageVersionsFromResolvedFile makes Xcode fail
# instead of picking newer versions.
xcode_build() {
  local flavor="$1" config="$2" scheme="$3" destination="$4"
  shift 4
  xcodebuild \
    -project "$REPO_ROOT/MyPass.xcodeproj" \
    -scheme "$scheme" \
    -configuration "$config" \
    -destination "$destination" \
    -derivedDataPath "$REPO_ROOT/build/$flavor" \
    -clonedSourcePackagesDirPath "$REPO_ROOT/build/SourcePackages" \
    -onlyUsePackageVersionsFromResolvedFile \
    "$@" \
    build
  verify_package_lock
}

# Unsigned overrides live on the xcodebuild command line only; project.yml keeps the stable
# DEVELOPMENT_TEAM (ad-hoc signing there would invalidate the biometric Keychain ACL, see
# project.yml).
UNSIGNED_SETTINGS=(CODE_SIGNING_ALLOWED=NO CODE_SIGN_ENTITLEMENTS=)

# Extra xcodebuild arguments for the Release `package` build only, filled by
# prepare_package_build_settings:
#   CLANG_COVERAGE_MAPPING=NO ENABLE_CODE_COVERAGE=NO
#                            Xcode turns coverage on by default (for the implicit scheme
#                            too); without this the Release app carries profile counters
#                            (___profc_ symbols naming every source file by absolute path)
#                            and runs slower. xcodebuild's -enableCodeCoverage flag is
#                            rejected outside `test`, hence the build settings.
#   -file-prefix-map /       the compilers rewrite the builder's home directory and the
#   -ffile-prefix-map        checkout path in everything they embed (#filePath, assert and
#                            precondition messages, debug info) to fixed placeholders
# Both prefixes are mapped HOME first, checkout second: the last matching map wins, so files
# of this repository get /mypass-src and anything else under HOME gets /builder-home.
# A path that cannot be written into a build setting unambiguously is not mapped; the scan in
# cmd_package then reports whatever is left instead of this hiding it.
PACKAGE_BUILD_SETTINGS=()
prepare_package_build_settings() {
  local swift_flags='$(inherited)' c_flags='$(inherited)' entry dir
  PACKAGE_BUILD_SETTINGS=(CLANG_COVERAGE_MAPPING=NO ENABLE_CODE_COVERAGE=NO)
  for entry in "${HOME:-}=/builder-home" "$REPO_ROOT=/mypass-src"; do
    dir="${entry%%=/*}"
    case "$dir" in
      ""|"/"|*[\"\\=\$]*)
        echo "Note: not mapping the path prefix '$dir' in the compiled output (empty, root, or it contains a quote, backslash, '=' or '\$')." >&2
        continue ;;
    esac
    swift_flags="$swift_flags -file-prefix-map \"$entry\""
    c_flags="$c_flags -ffile-prefix-map=\"$entry\""
  done
  PACKAGE_BUILD_SETTINGS+=("OTHER_SWIFT_FLAGS=$swift_flags" "OTHER_CFLAGS=$c_flags")
}

build_dev() {
  local unsigned="$1" flavor="dev"
  require_command xcodebuild "Install Xcode from the App Store."
  cmd_generate
  if [[ "$unsigned" == "1" ]]; then
    flavor="dev-unsigned"
    xcode_build "$flavor" Debug MyPass 'platform=macOS' "${UNSIGNED_SETTINGS[@]}"
    xcode_build "$flavor" Debug ChromeHost 'platform=macOS' "${UNSIGNED_SETTINGS[@]}"
  else
    xcode_build "$flavor" Debug MyPass 'platform=macOS'
    xcode_build "$flavor" Debug ChromeHost 'platform=macOS'
  fi
  BUILT_PRODUCTS="$REPO_ROOT/build/$flavor/Build/Products/Debug"
  [[ -d "$BUILT_PRODUCTS/MyPass.app" ]] || fail "MyPass.app not found at $BUILT_PRODUCTS after the build."
  [[ -x "$BUILT_PRODUCTS/ChromeHost" ]] || fail "ChromeHost not found at $BUILT_PRODUCTS after the build."
}

cmd_build() {
  local unsigned=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --unsigned) unsigned=1 ;;
      -h|--help) usage; exit 0 ;;
      *) usage_error "unknown option for 'build': $1" ;;
    esac
    shift
  done
  require_checkout build
  build_dev "$unsigned"
  echo "Built:"
  echo "  $BUILT_PRODUCTS/MyPass.app"
  echo "  $BUILT_PRODUCTS/ChromeHost"
}

# Running copies of this bundle id as "pid<TAB>executable path" lines, read through
# NSRunningApplication. It sees every copy, wherever it was launched from, and has no side
# effects. AppleScript's `application id ... is running` is avoided: for an unregistered id
# it can raise a "Where is ...?" dialog, and `tell application id ... to quit` addresses
# only whichever copy LaunchServices happens to resolve.
#
# Fails closed: the script prints an "OK" marker line before any entry, and anything else
# (osascript missing, a JavaScript error, no marker) returns 1 with no output. "No copies
# running" is therefore an empty list with status 0, never the same thing as "could not
# ask", so a broken enumeration cannot be mistaken for a clean machine.
mypass_running_copies() {
  local out first
  out="$(osascript -l JavaScript -e '
    ObjC.import("AppKit");
    function run(argv) {
      var apps = $.NSRunningApplication.runningApplicationsWithBundleIdentifier(argv[0]);
      var out = ["OK"];
      for (var i = 0; i < apps.count; i++) {
        var a = apps.objectAtIndex(i);
        if (a.isTerminated) continue;
        var url = a.executableURL;
        out.push(a.processIdentifier + "\t" + (url.isNil() ? "" : ObjC.unwrap(url.path)));
      }
      return out.join("\n");
    }' "$BUNDLE_ID" 2>/dev/null)" || return 1
  first="${out%%$'\n'*}"
  [[ "$first" == "OK" ]] || return 1
  if [[ "$out" == *$'\n'* ]]; then
    printf '%s\n' "${out#*$'\n'}"
  fi
  return 0
}

# Politely quits exactly one process (NSRunningApplication.terminate sends the normal Quit
# event, so the app's own save-flush and any Cancel / Quit Anyway prompt still run). The pid
# reaches osascript as an argument, never inside the script text. Returns 0 only when the
# request was delivered ("true") or the process was already gone ("gone"); never signals
# the process.
mypass_request_quit() {
  local out
  out="$(osascript -l JavaScript -e '
    ObjC.import("AppKit");
    function run(argv) {
      var a = $.NSRunningApplication.runningApplicationWithProcessIdentifier(parseInt(argv[0], 10));
      return (a.isNil() || a.isTerminated) ? "gone" : String(a.terminate);
    }' "$1" 2>/dev/null)" || return 1
  [[ "$out" == "true" || "$out" == "gone" ]]
}

# Set while `run` is building, so the EXIT trap can say what state a failed build leaves
# behind (see cleanup).
RUN_BUILD_IN_PROGRESS=0

# Quits EVERY running MyPass copy (whichever path it runs from) and returns only when none is
# left, or fails. Builds that carry the single-instance guard hand over by themselves, but a
# legacy copy has no listener and a sandboxed copy cannot be quit by another sandboxed app;
# this script is not sandboxed, so it can ask each copy to quit before anything is built.
# Every failure mode is a hard stop BEFORE the build: an unreadable process list, a process
# list entry that is not a plain pid, a quit request that was not delivered, a copy that is
# still alive after 15 s (it may be showing the Cancel / Quit Anyway save prompt, or be a
# build that ignores quit requests). Nothing is force-killed and no bundle is removed.
quit_running_mypass() {
  local copies pid path shown waited=0
  copies="$(mypass_running_copies)" \
    || fail "could not list the running MyPass copies (osascript failed), so it is unknown whether one holds the vault. Nothing was quit, built or launched."
  [[ -n "$copies" ]] || return 0

  # Validate the whole list before asking anyone to quit. The pid is later handed to
  # osascript as an argument; it must be a plain positive integer.
  while IFS=$'\t' read -r pid path; do
    [[ -n "$pid" ]] || continue
    if [[ ! "$pid" =~ ^[1-9][0-9]{0,9}$ ]]; then
      printf -v shown '%q' "$copies"
      fail "the running-copy list has an entry that is not a process id: $shown. Nothing was quit, built or launched."
    fi
  done <<<"$copies"

  echo "Asking the running MyPass copies to quit..."
  while IFS=$'\t' read -r pid path; do
    [[ -n "$pid" ]] || continue
    echo "  pid $pid (${path//[[:cntrl:]]/?})"
    mypass_request_quit "$pid" \
      || fail "could not ask MyPass (pid $pid) to quit. Nothing was force-killed, built or launched."
  done <<<"$copies"

  while (( waited < 15000 )); do
    copies="$(mypass_running_copies)" \
      || fail "could not re-read the running MyPass copies while waiting for them to quit. Nothing was built or launched."
    [[ -n "$copies" ]] || return 0
    sleep 0.2
    waited=$(( waited + 200 ))
  done
  copies="$(mypass_running_copies)" \
    || fail "could not re-read the running MyPass copies after waiting for them to quit. Nothing was built or launched."
  [[ -z "$copies" ]] && return 0
  fail "MyPass did not quit within 15 seconds (it may be showing a save prompt: answer it, or it may be a build that ignores quit requests): ${copies//$'\t'/ }. Quit it manually and run again. Nothing was force-killed, built or launched."
}

# Order matters, and it is the point of this function:
#   1. preflight every tool and the committed package locks (no side effects),
#   2. quit every running MyPass and wait until none is left,
#   3. only then build (a running executable inside build/dev would otherwise be rewritten
#      under a live process), and
#   4. open exactly the executable just built and verify it is the only MyPass.
# A failed quit stops before the build; a failed build leaves no MyPass running and says so,
# and never relaunches the previous app. Two independent `run` invocations may both get to
# `open -n`; the app's own single-instance gate decides, and step 4 reports the outcome.
cmd_run() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      *) usage_error "unknown option for 'run': $1" ;;
    esac
  done
  require_checkout run
  require_command osascript
  require_command open
  require_command xcodegen "Install with: brew install xcodegen"
  require_command xcodebuild "Install Xcode from the App Store."
  [[ -x /usr/libexec/PlistBuddy ]] || fail "/usr/libexec/PlistBuddy not found."
  package_lock_check_source
  package_lock_check_agreement

  quit_running_mypass

  echo "No MyPass is running; building. If the build fails MyPass stays closed."
  RUN_BUILD_IN_PROGRESS=1
  build_dev 0
  RUN_BUILD_IN_PROGRESS=0

  local app="$BUILT_PRODUCTS/MyPass.app" built_id waited=0 copies="" want
  built_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$built_id" == "$BUNDLE_ID" ]] || fail "$app is not a $BUNDLE_ID bundle (found '${built_id:-none}')."
  want="$app/Contents/MacOS/MyPass"
  [[ -x "$want" ]] || fail "the built executable $want is missing."

  # -n starts THIS bundle even if another copy of the same bundle id were registered; plain
  # `open` would just activate that other copy and report success.
  open -n "$app" || fail "open -n failed for $app"

  # The guard may briefly show a second process while a copy hands over; settle, then require
  # exactly one MyPass and that it is the executable just built.
  while (( waited < 15000 )); do
    copies="$(mypass_running_copies)" \
      || fail "could not read the running MyPass copies after launching $app, so the launch is unverified."
    if [[ -n "$copies" && "$(grep -c . <<<"$copies")" -eq 1 && "${copies#*$'\t'}" == "$want" ]]; then
      echo "Launched $app (pid ${copies%%$'\t'*})"
      return 0
    fi
    sleep 0.2
    waited=$(( waited + 200 ))
  done
  if [[ -z "$copies" ]]; then
    fail "MyPass did not start from $app"
  fi
  fail "expected exactly one running MyPass from $want, found: ${copies//$'\t'/ }"
}

# --- install-host --------------------------------------------------------------------------

# The one escape function for manifest JSON strings. Control characters and invalid UTF-8
# cannot be represented faithfully by `\` and `"` escaping alone, so paths containing them
# are refused up front (see reject_unrepresentable_path) instead of being half-escaped.
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

reject_unrepresentable_path() {
  local label="$1" value="$2"
  [[ -n "$value" ]] || fail "$label is empty."
  # Subshell so LC_ALL=C applies to the pattern match only: byte-wise, [[:cntrl:]] then
  # means exactly 0x00-0x1f and 0x7f, newline and tab included.
  if (LC_ALL=C; case "$value" in *[[:cntrl:]]*) exit 0 ;; esac; exit 1); then
    fail "$label contains a control character (newline, tab, ...), which a native messaging manifest path cannot hold safely: refusing."
  fi
  if command -v iconv >/dev/null 2>&1; then
    printf '%s' "$value" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 \
      || fail "$label is not valid UTF-8, so it cannot be written into a JSON manifest: refusing."
  fi
}

# check_dir_chain ROOT REL
# Walk REL (slash separated, relative to ROOT) and refuse if any component that already
# exists is a symbolic link or not a directory. Components that do not exist yet are fine:
# `mkdir -p` will create them as real directories under the ones just verified. Inherited
# symlinks are never trusted, so an installer run cannot be steered into writing elsewhere.
check_dir_chain() {
  local root="$1" rest="$2" cur="$1" part
  while [[ -n "$rest" ]]; do
    part="${rest%%/*}"
    if [[ "$rest" == */* ]]; then rest="${rest#*/}"; else rest=""; fi
    cur="$cur/$part"
    if [[ -L "$cur" ]]; then
      echo "Error: refusing to use '$cur': it is a symbolic link." >&2
      return 1
    fi
    if [[ -e "$cur" && ! -d "$cur" ]]; then
      echo "Error: refusing to use '$cur': it exists and is not a directory." >&2
      return 1
    fi
    [[ -e "$cur" ]] || break
  done
  return 0
}

# check_file_dest PATH: an existing final destination must be a plain regular file.
check_file_dest() {
  local path="$1"
  if [[ -L "$path" ]]; then
    echo "Error: refusing to overwrite '$path': it is a symbolic link." >&2
    return 1
  fi
  if [[ -d "$path" ]]; then
    echo "Error: refusing to overwrite '$path': it is a directory." >&2
    return 1
  fi
  if [[ -e "$path" && ! -f "$path" ]]; then
    echo "Error: refusing to overwrite '$path': it is not a regular file." >&2
    return 1
  fi
  return 0
}

# new_temp_file DIR PREFIX: mktemp inside the destination directory (same filesystem, so
# the final mv is a rename) and register it for cleanup. The path is returned in NEW_TMP,
# not on stdout: a command substitution would run in a subshell and lose the registration.
NEW_TMP=""
new_temp_file() {
  NEW_TMP="$(mktemp "$1/.$2.XXXXXX")" || fail "could not create a temporary file in '$1'."
  OWNED_TMP_FILES+=("$NEW_TMP")
}

write_manifest_to() {
  local target="$1" host_path_json="$2"
  printf '{\n  "allowed_origins": [\n    "chrome-extension://%s/"\n  ],\n  "description": "MyPass native messaging host",\n  "name": "%s",\n  "path": "%s",\n  "type": "stdio"\n}\n' \
    "$EXTENSION_ID" "$HOST_NAME" "$host_path_json" >"$target"
}

# How the host was chosen: "explicit" (--host), "beside dev.sh" or "autodetected". Anything
# but "explicit" is a guess that must not silently downgrade an installed host.
HOST_SELECTION=""
HOST_SELECTION_DETAIL=""
HOST_OTHER_CANDIDATES=()

resolve_host_source() {
  local explicit="$1" candidate
  HOST_OTHER_CANDIDATES=()
  if [[ -n "$explicit" ]]; then
    HOST_SRC="$explicit"
    HOST_SELECTION="explicit"
    HOST_SELECTION_DETAIL="--host"
  elif [[ -f "$SCRIPT_DIR/ChromeHost" ]]; then
    HOST_SRC="$SCRIPT_DIR/ChromeHost"
    HOST_SELECTION="beside dev.sh"
    HOST_SELECTION_DETAIL="ChromeHost next to dev.sh"
  elif [[ -n "$REPO_ROOT" ]]; then
    HOST_SRC=""
    # Fixed order, signed development build first. Newer is deliberately not a criterion
    # (the mtimes of unrelated builds say nothing about which one is wanted); instead every
    # other build found is listed, so the choice is never silent.
    for candidate in \
      "$REPO_ROOT/build/dev/Build/Products/Debug/ChromeHost" \
      "$REPO_ROOT/build/dev-unsigned/Build/Products/Debug/ChromeHost" \
      "$REPO_ROOT/build/package/Build/Products/Release/ChromeHost"; do
      if [[ -f "$candidate" && -x "$candidate" ]]; then
        if [[ -z "$HOST_SRC" ]]; then
          HOST_SRC="$candidate"
          HOST_SELECTION="autodetected"
          HOST_SELECTION_DETAIL="first of build/dev, build/dev-unsigned, build/package"
        else
          HOST_OTHER_CANDIDATES+=("$candidate")
        fi
      fi
    done
  else
    HOST_SRC=""
  fi
  if [[ -z "$HOST_SRC" ]]; then
    echo "Error: ChromeHost binary not found." >&2
    echo "Pass --host PATH, place ChromeHost next to dev.sh, or (in a checkout) run: scripts/dev.sh build" >&2
    exit 1
  fi
  [[ ! -d "$HOST_SRC" ]] || fail "host '$HOST_SRC' is a directory, expected the ChromeHost executable."
  [[ -f "$HOST_SRC" ]] || fail "host '$HOST_SRC' does not exist or is not a regular file."
  [[ -x "$HOST_SRC" ]] || fail "host '$HOST_SRC' is not executable."
}

# signing_flavor PATH: a one-line description of the code signature, from codesign (a base
# system tool). Xcode's "unsigned" builds still get a linker-made ad-hoc signature on
# arm64, so "ad-hoc signed" is the honest label for those and for package output.
signing_flavor() {
  local out team
  if ! command -v codesign >/dev/null 2>&1; then
    echo "unknown (codesign not available)"
    return 0
  fi
  out="$(codesign -dv "$1" 2>&1 || true)"
  if grep -q "not signed at all" <<<"$out"; then
    echo "unsigned"
    return 0
  fi
  team="$(sed -n 's/^TeamIdentifier=//p' <<<"$out")"
  if [[ -n "$team" && "$team" != "not set" ]]; then
    echo "team-signed (TeamIdentifier $team)"
  elif grep -q "^Signature=adhoc" <<<"$out"; then
    echo "ad-hoc signed (no team identity)"
  elif [[ -n "$out" ]]; then
    echo "signed (no team identity)"
  else
    echo "unknown"
  fi
}

# require_writable_target ROOT DIR WHAT: DIR, or its nearest existing ancestor when DIR does
# not exist yet, must be a writable, searchable directory. Checked before the first write so
# an unwritable destination refuses the whole install instead of failing half way.
require_writable_target() {
  local root="$1" dir="$2" what="$3" probe="$2"
  while [[ ! -e "$probe" && "$probe" != "$root" && "$probe" != "/" ]]; do
    probe="$(dirname "$probe")"
  done
  if [[ ! -d "$probe" || ! -w "$probe" || ! -x "$probe" ]]; then
    echo "Error: cannot install the $what: '$probe' is not a writable directory" >&2
    echo "       (needed to create or update '$dir'). Nothing was changed." >&2
    exit 1
  fi
}

cmd_install_host() {
  local host_arg="" root_arg="" root_given=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --host)
        [[ $# -ge 2 ]] || usage_error "--host needs a path."
        host_arg="$2"; shift ;;
      --install-root)
        [[ $# -ge 2 ]] || usage_error "--install-root needs a directory."
        root_arg="$2"; root_given=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage_error "unknown option for 'install-host': $1" ;;
    esac
    shift
  done

  # Only base-system tools: no python3, no Xcode.
  local tool
  for tool in cp mv chmod mkdir mktemp; do
    require_command "$tool"
  done

  resolve_host_source "$host_arg"

  local root_raw
  if (( root_given )); then
    root_raw="$root_arg"
  elif [[ -n "${MYPASS_INSTALL_ROOT:-}" ]]; then
    root_raw="$MYPASS_INSTALL_ROOT"
  else
    [[ -n "${HOME:-}" ]] || fail "HOME is not set; pass --install-root DIR."
    root_raw="$HOME"
  fi
  reject_unrepresentable_path "install root" "$root_raw"
  [[ -d "$root_raw" ]] || fail "install root '$root_raw' is not an existing directory."
  # The root itself may be reached through symlinks (/var -> /private/var for temp
  # directories, a relocated $HOME); everything below it must not be. Work on the physical
  # path so the symlink checks, the -ef check and the manifest path all agree.
  local root
  root="$(cd -P -- "$root_raw" && pwd)" || fail "cannot enter install root '$root_raw'."

  local app_support_rel="Library/Application Support"
  local host_dir_rel="$app_support_rel/MyPass"
  local host_dir="$root/$host_dir_rel"
  local host_dest="$host_dir/ChromeHost"

  reject_unrepresentable_path "host destination path" "$host_dest"

  # Preflight everything before writing anything: a refusal leaves the tree untouched.
  check_dir_chain "$root" "$host_dir_rel" || exit 1
  check_file_dest "$host_dest" || exit 1
  if [[ -e "$host_dest" && "$HOST_SRC" -ef "$host_dest" ]]; then
    fail "source and destination are the same file ('$host_dest'); nothing to do."
  fi

  # Say exactly which host is being installed and how it is signed.
  local src_flavor dest_flavor other newer
  src_flavor="$(signing_flavor "$HOST_SRC")"
  echo "Host to install: $HOST_SRC"
  echo "  selected by: $HOST_SELECTION ($HOST_SELECTION_DETAIL); signing: $src_flavor"
  for other in ${HOST_OTHER_CANDIDATES[@]+"${HOST_OTHER_CANDIDATES[@]}"}; do
    newer=""
    [[ "$other" -nt "$HOST_SRC" ]] && newer=", newer than the selected host"
    echo "  also found, not used: $other ($(signing_flavor "$other")$newer)" >&2
  done
  if [[ ${#HOST_OTHER_CANDIDATES[@]} -gt 0 ]]; then
    echo "  (pass --host PATH to install one of the others)" >&2
  fi
  # An installed team-signed host (the stable development signature) is never replaced by an
  # unsigned or ad-hoc one that was only guessed. Pass --host to do that on purpose.
  if [[ "$HOST_SELECTION" != "explicit" && -f "$host_dest" ]]; then
    dest_flavor="$(signing_flavor "$host_dest")"
    if [[ "$dest_flavor" == team-signed* && "$src_flavor" != team-signed* ]]; then
      echo "Error: the installed host '$host_dest' is $dest_flavor, but the host chosen automatically is $src_flavor." >&2
      echo "       Refusing to replace a signed host with a less-signed one by guesswork. Nothing was changed." >&2
      echo "       Pass --host PATH to install a specific host on purpose." >&2
      exit 1
    fi
  fi

  local base rel
  local manifest_dirs=()
  local skipped=()
  for base in "${CHROMIUM_BROWSER_BASES[@]}"; do
    rel="$app_support_rel/$base"
    if [[ "$base" == "Google/Chrome" || "$base" == "Google/Chrome for Testing" ]]; then
      check_dir_chain "$root" "$rel/NativeMessagingHosts" || exit 1
    elif [[ -e "$root/$rel" || -L "$root/$rel" ]]; then
      if ! check_dir_chain "$root" "$rel/NativeMessagingHosts" 2>/dev/null; then
        skipped+=("$base")
        continue
      fi
    else
      continue
    fi
    check_file_dest "$root/$rel/NativeMessagingHosts/$HOST_NAME.json" || exit 1
    manifest_dirs+=("$root/$rel/NativeMessagingHosts")
  done

  # Every destination directory must be writable before anything is written.
  local wdir
  require_writable_target "$root" "$host_dir" "host"
  for wdir in ${manifest_dirs[@]+"${manifest_dirs[@]}"}; do
    require_writable_target "$root" "$wdir" "native messaging manifest"
  done

  if command -v xattr >/dev/null 2>&1 && xattr -p com.apple.quarantine "$HOST_SRC" >/dev/null 2>&1; then
    echo "Note: '$HOST_SRC' carries the macOS quarantine flag; Chrome may refuse to start the copy." >&2
    echo "      Remove it first with: xattr -dr com.apple.quarantine <extracted folder>" >&2
  fi

  # Stage every file first (a temp file in its own destination directory, so the final mv is
  # a rename on the same filesystem), then rename them into place. If creating any temp file
  # fails, the installed host has not been touched yet. The host is copied and renamed
  # rather than rewritten in place: a running or half-copied host is never visible, and the
  # copy gets a new inode (rewriting a code-signed binary in place can make macOS kill it on
  # next launch).
  mkdir -p -- "$host_dir"
  local tmp host_tmp host_json dir manifest i
  new_temp_file "$host_dir" ChromeHost
  host_tmp="$NEW_TMP"
  cp -- "$HOST_SRC" "$host_tmp"
  chmod 755 "$host_tmp"

  local staged_tmp=() staged_dest=()
  host_json="$(json_escape "$host_dest")"
  for dir in ${manifest_dirs[@]+"${manifest_dirs[@]}"}; do
    mkdir -p -- "$dir"
    new_temp_file "$dir" "$HOST_NAME"
    tmp="$NEW_TMP"
    write_manifest_to "$tmp" "$host_json"
    chmod 644 "$tmp"
    staged_tmp+=("$tmp")
    staged_dest+=("$dir/$HOST_NAME.json")
  done

  mv -f -- "$host_tmp" "$host_dest"
  local installed=()
  for (( i = 0; i < ${#staged_tmp[@]}; i++ )); do
    mv -f -- "${staged_tmp[$i]}" "${staged_dest[$i]}"
    installed+=("${staged_dest[$i]}")
  done

  echo "Installed host: $host_dest"
  echo "Installed native messaging host manifests:"
  for manifest in "${installed[@]}"; do
    echo "  $manifest"
  done
  if [[ ${#skipped[@]} -gt 0 ]]; then
    echo "Skipped (browser directory is a symbolic link or otherwise not a plain directory):" >&2
    for base in "${skipped[@]}"; do
      echo "  $base" >&2
    done
  fi
  echo
  echo "Next: load the MyPass extension in your browser (its ID must be $EXTENSION_ID),"
  echo "then pair it from MyPass Settings."
}

# --- package -------------------------------------------------------------------------------

# MARKETING_VERSION of one target in project.yml. Targets and packages are both two-space
# keys, so match the exact target name, then take the first MARKETING_VERSION inside it.
project_version() {
  awk -v target="$1" '
    /^  [A-Za-z0-9_]+:[[:space:]]*$/ { in_target = ($1 == target ":") }
    in_target && /MARKETING_VERSION:/ { v = $2; gsub(/["\047]/, "", v); print v; exit }
  ' "$REPO_ROOT/project.yml"
}

# Set the app, host and extension version together: MARKETING_VERSION in both project.yml
# targets (MyPass, ChromeHost) and "version" in ChromeExtension/manifest.json. Plain X.Y.Z
# only, because Chrome rejects pre-release suffixes in manifest versions. Rewrites go through
# temp files next to the originals (registered for the EXIT trap) instead of `sed -i ''`, so
# the function does not depend on BSD/GNU sed flag differences; nothing is written back until
# both rewrites are validated, and the originals are then overwritten in place with `cat >`
# to keep their file mode. Does not commit.
cmd_set_version() {
  case "${1:-}" in -h|--help) usage; return 0 ;; esac
  [[ $# -eq 1 ]] || usage_error "set-version takes exactly one argument: X.Y.Z"
  require_checkout set-version
  local v="$1"
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || usage_error "version must be plain X.Y.Z (digits only, no 'v' prefix or suffix): '$v'"

  local yml="$REPO_ROOT/project.yml" manifest="$REPO_ROOT/ChromeExtension/manifest.json"
  local yml_tmp manifest_tmp count
  yml_tmp="$(mktemp "$yml.XXXXXX")"
  OWNED_TMP_FILES+=("$yml_tmp")
  manifest_tmp="$(mktemp "$manifest.XXXXXX")"
  OWNED_TMP_FILES+=("$manifest_tmp")

  # Keep the quoting style project.yml already uses ("0.2.0").
  sed -E 's/^([[:space:]]*MARKETING_VERSION:[[:space:]]*)"[^"]*"/\1"'"$v"'"/' "$yml" > "$yml_tmp"
  count="$(grep -c "^[[:space:]]*MARKETING_VERSION:[[:space:]]*\"$v\"" "$yml_tmp" || true)"
  [[ "$count" -eq 2 ]] \
    || fail "expected exactly 2 quoted MARKETING_VERSION lines in project.yml, rewrote $count."

  # Only the first "version" key: later ones (if any) belong to nested objects.
  awk -v v="$v" '
    !done && /^[[:space:]]*"version":/ {
      sub(/"version":[[:space:]]*"[^"]*"/, "\"version\": \"" v "\"")
      done = 1; n++
    }
    { print }
    END { if (n != 1) exit 3 }
  ' "$manifest" > "$manifest_tmp" \
    || fail "expected exactly 1 \"version\" line in ChromeExtension/manifest.json."
  grep -q "^[[:space:]]*\"version\": \"$v\"" "$manifest_tmp" \
    || fail "ChromeExtension/manifest.json \"version\" line is not a quoted string."

  cat "$yml_tmp" > "$yml"
  cat "$manifest_tmp" > "$manifest"
  echo "updated project.yml (2 targets)"
  echo "updated ChromeExtension/manifest.json"
}

# Every file the extension refers to by name must be in the staged package. Sources checked:
# manifest.json strings, importScripts() and chrome.runtime.getURL() literals in the staged
# scripts, and src/href attributes in the staged pages. Done with grep/sed so packaging does
# not need node. Fails (listing every miss) instead of shipping an extension that breaks at
# load time.
verify_extension_references() {
  local ext="$1" missing=0 ref file dir

  check_ref() { # check_ref REFERENCED_BY BASE_DIR REF
    local ref="$3"
    ref="${ref%%\#*}"
    ref="${ref%%\?*}"
    [[ -n "$ref" ]] || return 0
    case "$ref" in
      http:*|https:*|data:*|chrome-extension:*|//*|/*) return 0 ;;
    esac
    if [[ ! -f "$2/$ref" ]]; then
      echo "Error: $1 references '$ref', which is missing from the extension package." >&2
      missing=1
    fi
  }

  local manifest_refs
  manifest_refs="$(grep -oE '"[^"]+\.(js|html|css|png|svg|json)"' "$ext/manifest.json" | tr -d '"' || true)"
  [[ -n "$manifest_refs" ]] || fail "found no file references in the extension manifest.json; refusing to package."
  while IFS= read -r ref; do
    [[ -n "$ref" ]] && check_ref manifest.json "$ext" "$ref"
  done <<EOF
$manifest_refs
EOF

  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    while IFS= read -r ref; do
      [[ -n "$ref" ]] && check_ref "${file#"$ext"/}" "$ext" "$ref"
    done <<EOF
$(grep -ohE "(importScripts|getURL)\(['\"][^'\"]+['\"]" "$file" | sed -E "s/^[A-Za-z]+\(['\"]//; s/['\"]\$//" || true)
EOF
  done <<EOF
$(find "$ext" -type f -name '*.js' | LC_ALL=C sort)
EOF

  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    dir="$(dirname "$file")"
    while IFS= read -r ref; do
      [[ -n "$ref" ]] && check_ref "${file#"$ext"/}" "$dir" "$ref"
    done <<EOF
$(grep -ohE '(src|href)="[^"]*"' "$file" | sed -E 's/^(src|href)="//; s/"$//' || true)
EOF
  done <<EOF
$(find "$ext" -type f -name '*.html' | LC_ALL=C sort)
EOF

  (( missing == 0 )) || exit 1
}

# Text files (scripts, notices, manifest, pages) must not carry a macOS home-directory
# path. Compiled binaries are only reported: Swift and SwiftPM can embed absolute build
# paths, which is informational for the artifact but should be looked at. The prefix is
# built from pieces so this script, which ships in the dmg, does not match its own scan.
scan_for_personal_paths() {
  local stage="$1" label="$2" hits users_dir="/Us""ers"
  hits="$(grep -rIl -e "$users_dir/" "$stage" 2>/dev/null || true)"
  if [[ -n "$hits" ]]; then
    echo "Error: $label contains a macOS home-directory path in:" >&2
    printf '%s\n' "$hits" >&2
    exit 1
  fi
}

# Run a command, showing its output only when it fails (codesign chatters with temp paths).
quiet_unless_failed() {
  local output
  if ! output="$("$@" 2>&1)"; then
    printf '%s\n' "$output" >&2
    fail "command failed: $*"
  fi
}

cmd_package() {
  local out_dir="$REPO_ROOT/dist" release=0
  [[ -n "$REPO_ROOT" ]] || out_dir=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --out)
        [[ $# -ge 2 ]] || usage_error "--out needs a directory."
        out_dir="$2"; shift ;;
      --release) release=1 ;;
      -h|--help) usage; exit 0 ;;
      *) usage_error "unknown option for 'package': $1" ;;
    esac
    shift
  done
  require_checkout package
  require_command xcodebuild "Install Xcode from the App Store."
  require_command codesign
  require_command ditto
  require_command hdiutil
  require_command zip "Install the zip command line tool."
  require_command unzip
  require_command lipo
  require_command strip
  require_command shasum
  require_command git

  # Fail on missing inputs before spending minutes on a build.
  local f
  for f in LICENSE THIRD_PARTY_NOTICES.md scripts/package/INSTALL.txt ChromeExtension/manifest.json project.yml; do
    [[ -f "$REPO_ROOT/$f" ]] || fail "required file '$f' is missing from the repository."
  done

  local version host_version ext_version
  version="$(project_version MyPass)"
  host_version="$(project_version ChromeHost)"
  ext_version="$(sed -n '/^[[:space:]]*"version":[[:space:]]*"/{s/^[^:]*:[[:space:]]*"\([^"]*\)".*/\1/p;q;}' "$REPO_ROOT/ChromeExtension/manifest.json")"
  [[ "$version" =~ ^[0-9][0-9A-Za-z.+-]*$ ]] || fail "could not read MARKETING_VERSION for the MyPass target from project.yml (got '$version')."
  [[ "$host_version" == "$version" ]] || fail "version mismatch: MyPass is $version but ChromeHost is '$host_version' in project.yml."
  [[ "$ext_version" == "$version" ]] || fail "version mismatch: MyPass is $version but ChromeExtension/manifest.json is '$ext_version'."

  # Release mode refuses before the build: a release must be exactly the tagged commit, so
  # a dirty tree or a HEAD that is not at tag v<version> fails in seconds, not after minutes.
  if [[ "$release" == 1 ]]; then
    [[ -z "$(git -C "$REPO_ROOT" status --porcelain)" ]] || fail "release mode needs a clean working tree (and HEAD at tag v$version)."
    local tag
    tag="$(git -C "$REPO_ROOT" describe --exact-match --tags 2>/dev/null || true)"
    [[ "$tag" == "v$version" ]] || fail "release mode needs HEAD at tag v$version (found '${tag:-no tag}')."
  fi

  mkdir -p -- "$out_dir"
  local out_abs
  out_abs="$(cd -P -- "$out_dir" && pwd)" || fail "cannot enter output directory '$out_dir'."

  cmd_generate

  # Release, arm64 only, no signing at all (CODE_SIGNING_ALLOWED=NO, no entitlements): the
  # sealing below is a separate, explicit ad-hoc step on copies, so build/package stays an
  # unmodified compiler output.
  local flavor=package dest='platform=macOS,arch=arm64' scheme
  prepare_package_build_settings
  for scheme in MyPass ChromeHost; do
    xcode_build "$flavor" Release "$scheme" "$dest" ARCHS=arm64 ONLY_ACTIVE_ARCH=NO "${UNSIGNED_SETTINGS[@]}" "${PACKAGE_BUILD_SETTINGS[@]}"
  done
  local products="$REPO_ROOT/build/package/Build/Products/Release"
  [[ -d "$products/MyPass.app" ]] || fail "MyPass.app not found at $products after the build."
  [[ -x "$products/ChromeHost" ]] || fail "ChromeHost not found at $products after the build."

  local app_exe built_version archs
  app_exe="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$products/MyPass.app/Contents/Info.plist")"
  built_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$products/MyPass.app/Contents/Info.plist")"
  [[ "$built_version" == "$version" ]] || fail "built app reports version '$built_version', expected $version."
  archs="$(lipo -archs "$products/MyPass.app/Contents/MacOS/$app_exe")"
  [[ "$archs" == "arm64" ]] || fail "MyPass executable architectures are '$archs', expected exactly 'arm64'."
  archs="$(lipo -archs "$products/ChromeHost")"
  [[ "$archs" == "arm64" ]] || fail "ChromeHost architectures are '$archs', expected exactly 'arm64'."

  # Provenance is part of the name, evaluated after the build so anything the build touched
  # counts: a tree with uncommitted changes is labelled -dirty and never looks like a clean
  # build of that commit.
  local provenance
  if git -C "$REPO_ROOT" rev-parse --verify HEAD >/dev/null 2>&1; then
    provenance="$(git -C "$REPO_ROOT" rev-parse --short=7 HEAD)"
    if [[ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]]; then
      provenance="$provenance-dirty"
      echo "Note: the working tree has uncommitted changes; artifacts are named -dirty."
    fi
  else
    provenance="nogit"
  fi

  local dmg_base="MyPass-$version-macos-arm64-$provenance"
  local ext_base="MyPass-chrome-extension-$version-$provenance"
  if [[ "$release" == 1 ]]; then
    # The build must not have modified or added any file, or the artifacts would not be
    # the tagged commit. Re-checked here because the pre-build check cannot see build effects.
    [[ -z "$(git -C "$REPO_ROOT" status --porcelain)" ]] || fail "release mode: the working tree became dirty during the build; refusing to publish artifacts that are not the tagged commit (tag v$version)."
    dmg_base="MyPass-$version-macos-arm64"
    ext_base="MyPass-chrome-extension-$version"
  fi

  OWNED_STAGE_PARENT="$out_abs"
  OWNED_STAGE_DIR="$(mktemp -d "$out_abs/.package-stage.XXXXXX")" || fail "could not create a staging directory in '$out_abs'."

  # --- macOS artifact ---
  # A plain directory, not nested under a named folder: hdiutil -srcfolder makes the folder's
  # contents the volume root.
  local mac_stage="$OWNED_STAGE_DIR/dmg"
  mkdir -p -- "$mac_stage"
  ditto --norsrc --noextattr --noqtn "$products/MyPass.app" "$mac_stage/MyPass.app"
  cp -- "$products/ChromeHost" "$mac_stage/ChromeHost"
  cp -- "$SCRIPT_PATH" "$mac_stage/dev.sh"
  cp -- "$REPO_ROOT/scripts/package/INSTALL.txt" "$mac_stage/INSTALL.txt"
  cp -- "$REPO_ROOT/LICENSE" "$mac_stage/LICENSE"
  cp -- "$REPO_ROOT/THIRD_PARTY_NOTICES.md" "$mac_stage/THIRD_PARTY_NOTICES.md"
  chmod 755 "$mac_stage/dev.sh" "$mac_stage/ChromeHost"

  # Drop the linker's debug map from the staged copies (build/package stays untouched). It
  # lists every object file by absolute build path, which -file-prefix-map cannot reach, and
  # nothing at run time uses it. This must come before the seal: stripping invalidates a
  # signature.
  quiet_unless_failed strip -S "$mac_stage/MyPass.app/Contents/MacOS/$app_exe"
  quiet_unless_failed strip -S "$mac_stage/ChromeHost"

  # Ad-hoc seal only: makes the bundle internally consistent so it loads on Apple Silicon.
  # No identity, no entitlements, no hardened runtime, no notarization (see INSTALL.txt).
  quiet_unless_failed codesign --force --deep -s - "$mac_stage/MyPass.app"
  quiet_unless_failed codesign --force -s - --identifier "$HOST_NAME" "$mac_stage/ChromeHost"
  quiet_unless_failed codesign --verify --deep --strict "$mac_stage/MyPass.app"
  quiet_unless_failed codesign --verify --strict "$mac_stage/ChromeHost"
  echo "codesign summary (ad hoc, no entitlements):"
  codesign -dv --verbose=2 "$mac_stage/MyPass.app" 2>&1 | grep -E '^(Identifier|Format|Signature|CodeDirectory|TeamIdentifier)' | sed 's/^/  MyPass.app: /' || true
  codesign -dv --verbose=2 "$mac_stage/ChromeHost" 2>&1 | grep -E '^(Identifier|Format|Signature|CodeDirectory|TeamIdentifier)' | sed 's/^/  ChromeHost: /' || true

  scan_for_personal_paths "$mac_stage" "the macOS artifact"
  # Compiled files are scanned too (the text scan above skips binaries). With the prefix maps,
  # the disabled coverage and strip -S above, nothing of the builder's home or checkout path is
  # left in the measured Release output, so any hit is a regression: refuse to ship it.
  local embedded prefix
  for prefix in "${HOME:-}" "$REPO_ROOT"; do
    [[ -n "$prefix" && "$prefix" != "/" ]] || continue
    embedded="$(grep -rla -F -e "$prefix/" "$mac_stage/MyPass.app" "$mac_stage/ChromeHost" 2>/dev/null || true)"
    if [[ -n "$embedded" ]]; then
      echo "Error: the builder path '$prefix/' is embedded in compiled files of the macOS artifact:" >&2
      while IFS= read -r f; do
        echo "  ${f#"$mac_stage"/}" >&2
      done <<EOF
$embedded
EOF
      exit 1
    fi
  done

  # Drag-to-install shortcut. Created last so no recursive scan above follows it into
  # /Applications, and it is not part of the signed content.
  ln -s /Applications "$mac_stage/Applications"

  # --- extension artifact ---
  # Everything under ChromeExtension/ except tests and hidden files: new runtime files are
  # picked up automatically, and verify_extension_references below proves nothing the
  # extension loads is left out.
  local ext_stage="$OWNED_STAGE_DIR/ext"
  mkdir -p -- "$ext_stage"
  if [[ -n "$(find "$REPO_ROOT/ChromeExtension" -type l ! -path "$REPO_ROOT/ChromeExtension/tests/*" -print -quit)" ]]; then
    fail "ChromeExtension/ contains a symbolic link outside tests/; refusing to package."
  fi
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    mkdir -p -- "$ext_stage/$(dirname "$f")"
    cp -- "$REPO_ROOT/ChromeExtension/$f" "$ext_stage/$f"
  done <<EOF
$(cd "$REPO_ROOT/ChromeExtension" && find . -type f ! -path './tests' ! -path './tests/*' ! -path '*/.*' ! -name '*.test.js' ! -name '*~' | sed 's|^\./||' | LC_ALL=C sort)
EOF
  cp -- "$REPO_ROOT/LICENSE" "$ext_stage/LICENSE"
  cp -- "$REPO_ROOT/THIRD_PARTY_NOTICES.md" "$ext_stage/THIRD_PARTY_NOTICES.md"
  [[ -f "$ext_stage/manifest.json" ]] || fail "manifest.json is missing from the staged extension."
  verify_extension_references "$ext_stage"
  scan_for_personal_paths "$ext_stage" "the extension artifact"

  # --- dmg and zip, verify, move into place ---
  local dmg_tmp="$OWNED_STAGE_DIR/$dmg_base.dmg" ext_tmp="$OWNED_STAGE_DIR/$ext_base.zip"
  (cd "$ext_stage" && find . -type f | sed 's|^\./||' | LC_ALL=C sort | zip -X -q "$ext_tmp" -@)

  local listing entry
  listing="$(unzip -Z1 "$ext_tmp")"
  # Here-strings, not `printf | grep -q`: grep -q exits at the first match, and under
  # pipefail the printf writer then dies of SIGPIPE on a large listing and fails the test.
  if grep -qE '(^|/)tests/|(^|/)\.DS_Store$|\.test\.js$' <<<"$listing"; then
    fail "the extension zip contains test or Finder files."
  fi
  for entry in manifest.json LICENSE THIRD_PARTY_NOTICES.md; do
    grep -qxF "$entry" <<<"$listing" || fail "the extension zip is missing '$entry'."
  done

  # The stage becomes the volume root, so check it exactly before imaging.
  if [[ -n "$(find "$mac_stage" \( -name .DS_Store -o -name __MACOSX \) -print -quit)" ]]; then
    fail "the macOS stage contains Finder files (.DS_Store or __MACOSX)."
  fi
  for entry in dev.sh ChromeHost INSTALL.txt LICENSE THIRD_PARTY_NOTICES.md MyPass.app/Contents/Info.plist; do
    [[ -e "$mac_stage/$entry" ]] || fail "the macOS stage is missing '$entry'."
  done
  listing="$(ls -A "$mac_stage" | LC_ALL=C sort)"
  [[ "$listing" == "$(printf '%s\n' Applications ChromeHost INSTALL.txt LICENSE MyPass.app THIRD_PARTY_NOTICES.md dev.sh)" ]] \
    || fail "the macOS stage has unexpected contents: $(tr '\n' ' ' <<<"$listing")"
  [[ "$(readlink "$mac_stage/Applications")" == /Applications ]] || fail "the Applications link in the macOS stage is wrong."

  quiet_unless_failed hdiutil create -srcfolder "$mac_stage" -volname "MyPass $version" -fs HFS+ -format UDZO -ov "$dmg_tmp"
  quiet_unless_failed hdiutil verify "$dmg_tmp"

  local final
  for final in "$out_abs/$dmg_base.dmg" "$out_abs/$ext_base.zip"; do
    [[ ! -d "$final" ]] || fail "'$final' is a directory; refusing to replace it."
  done
  mv -f -- "$dmg_tmp" "$out_abs/$dmg_base.dmg"
  mv -f -- "$ext_tmp" "$out_abs/$ext_base.zip"
  if [[ "$release" == 1 ]]; then
    # Basenames only, DMG first: users run `shasum -a 256 -c SHA256SUMS.txt` in the folder
    # holding the downloads, so the file must not carry build-machine paths.
    (cd "$out_abs" && shasum -a 256 "$dmg_base.dmg" "$ext_base.zip" > SHA256SUMS.txt)
  fi

  echo
  echo "Development artifacts (unsigned, ad-hoc sealed; not a supported way to run a real vault):"
  (cd "$out_abs" && shasum -a 256 "$dmg_base.dmg" "$ext_base.zip")
  echo "  $out_abs/$dmg_base.dmg"
  echo "  $out_abs/$ext_base.zip"
}

# --- dispatch ------------------------------------------------------------------------------

main() {
  if [[ $# -eq 0 ]]; then
    usage_error "missing command."
  fi
  local command_name="$1"
  shift
  case "$command_name" in
    generate) cmd_generate "$@" ;;
    build) cmd_build "$@" ;;
    run) cmd_run "$@" ;;
    install-host) cmd_install_host "$@" ;;
    package) cmd_package "$@" ;;
    set-version) cmd_set_version "$@" ;;
    -h|--help|help) usage ;;
    *) usage_error "unknown command: $command_name" ;;
  esac
}

# Run only when executed, so isolated checks can `source` this file for its functions.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
