#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

EXTENSION_ID="hjijbabodfldconmhdcdphlbgaajkejn"
STABLE_DIR="${HOME}/Library/Application Support/MyPass"
# Must match NativeMessagingHostInstaller.chromeHostBinaryPath in the app.
HOST_BINARY="${STABLE_DIR}/ChromeHost"
TARGET_DIR="${HOME}/Library/Application Support/Google/Chrome/NativeMessagingHosts"
MANIFEST_PATH="${TARGET_DIR}/com.mypass.chromehost.json"

"$REPO_ROOT/scripts/build-chrome-host.sh"

TARGET_BUILD_DIR="$(cd "$REPO_ROOT" && xcodebuild -project MyPass.xcodeproj -scheme ChromeHost -destination 'platform=macOS' -showBuildSettings 2>/dev/null | sed -n 's/^ *TARGET_BUILD_DIR = //p' | head -n 1)"

if [[ -z "$TARGET_BUILD_DIR" ]]; then
  echo "Error: could not resolve TARGET_BUILD_DIR from xcodebuild -showBuildSettings." >&2
  exit 1
fi

if [[ ! -x "$TARGET_BUILD_DIR/ChromeHost" ]]; then
  echo "Error: ChromeHost binary not found at $TARGET_BUILD_DIR/ChromeHost after build." >&2
  exit 1
fi

mkdir -p "$STABLE_DIR"
cp "$TARGET_BUILD_DIR/ChromeHost" "$HOST_BINARY"
chmod 755 "$HOST_BINARY"

mkdir -p "$TARGET_DIR"

python3 -c "
import json

manifest = {
    'allowed_origins': ['chrome-extension://${EXTENSION_ID}/'],
    'description': 'MyPass native messaging host',
    'name': 'com.mypass.chromehost',
    'path': '${HOST_BINARY}',
    'type': 'stdio',
}

with open('${MANIFEST_PATH}', 'w', encoding='utf-8') as f:
    json.dump(manifest, f, indent=2, sort_keys=True)
    f.write('\n')
"

echo "Installed native messaging host manifest:"
echo "  $MANIFEST_PATH"
echo
echo "Next steps:"
echo "  1. In Chrome, open chrome://extensions and load (or reload) the unpacked"
echo "     extension from ChromeExtension/ — its ID must be ${EXTENSION_ID}."
echo "  2. MyPass Settings → Browser no longer requires manual steps for this"
echo "     Chrome profile (extension ID is pre-filled; host manifest is installed)."
