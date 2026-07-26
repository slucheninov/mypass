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

"$ROOT/scripts/generate.sh"

xcodebuild -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS' build
