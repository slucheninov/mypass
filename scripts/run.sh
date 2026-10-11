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

"$ROOT/scripts/launch-mypass.sh" "$APP"
