#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

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

"$ROOT/scripts/build.sh"

BUILT_PRODUCTS_DIR=$(
  xcodebuild -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/^[[:space:]]*BUILT_PRODUCTS_DIR / {print $2; exit}'
)

APP=""
if [[ -n "${BUILT_PRODUCTS_DIR:-}" ]]; then
  APP="$BUILT_PRODUCTS_DIR/MyPass.app"
fi

if [[ -z "$APP" || ! -d "$APP" ]]; then
  APP=$(
    find ~/Library/Developer/Xcode/DerivedData -maxdepth 3 -type d -name 'MyPass.app' -path '*/Build/Products/Debug/*' -print0 2>/dev/null \
      | xargs -0 stat -f '%m %N' 2>/dev/null \
      | sort -rn \
      | head -1 \
      | cut -d' ' -f2- \
      || true
  )
fi

if [[ -z "$APP" || ! -d "$APP" ]]; then
  echo "Error: MyPass.app not found after build." >&2
  echo "Tried BUILT_PRODUCTS_DIR from xcodebuild -showBuildSettings and DerivedData search." >&2
  exit 1
fi

# Incremental builds can update AppIcon.icns without changing the .app bundle mtime, leaving Dock/Launch Services icon cache stale.
touch "$APP"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$APP" || true
fi

stop_running_mypass() {
  local pattern='MyPass\.app/Contents/MacOS/MyPass'
  local pids=""
  # pgrep exits 1 when nothing matches; under `set -e` that would abort the
  # script, so guard it explicitly.
  pids=$(pgrep -f "$pattern" || true)
  # Never target our own process (paranoia: pgrep -f matches full argv).
  pids=$(printf '%s\n' "$pids" | grep -v -x "$$" || true)
  [[ -z "$pids" ]] && return 0

  local pids_before="$pids"
  for pid in $pids; do
    kill -TERM "$pid" 2>/dev/null || true
  done

  local waited=0
  while (( waited < 5000 )); do
    pids=$(pgrep -f "$pattern" || true)
    pids=$(printf '%s\n' "$pids" | grep -v -x "$$" || true)
    [[ -z "$pids" ]] && break
    sleep 0.2
    waited=$(( waited + 200 ))
  done

  if [[ -n "$pids" ]]; then
    for pid in $pids; do
      kill -KILL "$pid" 2>/dev/null || true
    done
    sleep 0.2
    pids=$(pgrep -f "$pattern" || true)
    pids=$(printf '%s\n' "$pids" | grep -v -x "$$" || true)
  fi

  if [[ -n "$pids" ]]; then
    echo "Error: could not stop running MyPass instance(s): $pids" >&2
    echo "Inspect with: ps -p $pids -o pid,ppid,command" >&2
    exit 1
  fi

  echo "Stopped running MyPass (pid $(printf '%s' "$pids_before" | tr '\n' ' ' | sed 's/ *$//'))"
}

stop_running_mypass

open "$APP"
