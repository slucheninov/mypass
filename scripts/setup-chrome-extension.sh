#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

EXTENSION_ID="hjijbabodfldconmhdcdphlbgaajkejn"
STABLE_DIR="${HOME}/Library/Application Support/MyPass"
# Must match NativeMessagingHostInstaller.chromeHostBinaryPath in the app.
HOST_BINARY="${STABLE_DIR}/ChromeHost"
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

APP_SUPPORT="${HOME}/Library/Application Support"

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

INSTALLED_MANIFESTS=()

for base in "${CHROMIUM_BROWSER_BASES[@]}"; do
  base_dir="${APP_SUPPORT}/${base}"
  if [[ "$base" == "Google/Chrome" || "$base" == "Google/Chrome for Testing" ]] || [[ -d "$base_dir" ]]; then
    target_dir="${base_dir}/NativeMessagingHosts"
    manifest_path="${target_dir}/com.mypass.chromehost.json"
    mkdir -p "$target_dir"
    python3 -c "
import json

manifest = {
    'allowed_origins': ['chrome-extension://${EXTENSION_ID}/'],
    'description': 'MyPass native messaging host',
    'name': 'com.mypass.chromehost',
    'path': '${HOST_BINARY}',
    'type': 'stdio',
}

with open('${manifest_path}', 'w', encoding='utf-8') as f:
    json.dump(manifest, f, indent=2, sort_keys=True)
    f.write('\n')
"
    INSTALLED_MANIFESTS+=("$manifest_path")
  fi
done

echo "Installed native messaging host manifests:"
for manifest in "${INSTALLED_MANIFESTS[@]}"; do
  echo "  $manifest"
done
echo
echo "Next steps:"
echo "  1. In Chrome, open chrome://extensions and load (or reload) the unpacked"
echo "     extension from ChromeExtension/ — its ID must be ${EXTENSION_ID}."
echo "  2. MyPass Settings → Browser no longer requires manual steps for this"
echo "     Chrome profile (extension ID is pre-filled; host manifest is installed)."
