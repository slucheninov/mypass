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
require_command swift "Install Xcode from the App Store."

"$ROOT/scripts/generate.sh"

xcodebuild test -project MyPass.xcodeproj -scheme MyPass -destination 'platform=macOS'

(cd Packages/MyPassKit && swift test)
(cd Packages/SyncKit && swift test)
(cd Packages/ExtensionBridgeKit && swift test)

if command -v node >/dev/null 2>&1; then
  node ChromeExtension/tests/background.manifest.test.js
  node ChromeExtension/tests/backgroundRelay.test.js
  node ChromeExtension/tests/formDetection.test.js
  node ChromeExtension/tests/pairing.test.js
  node ChromeExtension/tests/letter-avatar.test.js
  node ChromeExtension/tests/popup-fallback.test.js
  node ChromeExtension/tests/unlockButton.test.js
  node ChromeExtension/tests/totpCircle.test.js
  node ChromeExtension/tests/totpDetection.test.js
  node ChromeExtension/tests/totpBanner.test.js
  node ChromeExtension/tests/totpPicker.test.js
  node ChromeExtension/tests/passkeyProxy.test.js
  node ChromeExtension/tests/passkeyPopup.test.js
  node ChromeExtension/tests/inlineIcon.test.js
  node ChromeExtension/tests/scriptScopes.test.js
else
  echo "Warning: node not found — skipping ChromeExtension JS tests." >&2
fi
