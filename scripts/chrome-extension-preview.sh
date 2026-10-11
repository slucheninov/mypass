#!/usr/bin/env bash
# Launch Chrome for Testing with the unpacked extension and a separate profile.
# Branded Chrome ignores --load-extension. This browser is only for extension checks.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="${MYPASS_CHROME_CACHE:-${HOME}/Library/Caches/mypass-chrome-for-testing}"
VERSION="${MYPASS_CHROME_VERSION:-155.0.8059.39}"
APP="${CACHE}/chrome-mac-arm64/Google Chrome for Testing.app"
BIN="${APP}/Contents/MacOS/Google Chrome for Testing"
PROFILE="${MYPASS_CHROME_PROFILE:-${CACHE}/profile}"
ZIP_URL="https://storage.googleapis.com/chrome-for-testing-public/${VERSION}/mac-arm64/chrome-mac-arm64.zip"

if [[ ! -x "$BIN" ]]; then
  mkdir -p "$CACHE"
  TMP_ZIP="$(mktemp "${CACHE}/chrome.XXXXXX.zip")"
  curl -fsSL "$ZIP_URL" -o "$TMP_ZIP"
  unzip -q -o "$TMP_ZIP" -d "$CACHE"
  rm -f "$TMP_ZIP"
  xattr -dr com.apple.quarantine "$APP" || true
fi

if [[ ! -x "$BIN" ]]; then
  echo "Chrome for Testing did not unpack to ${BIN}" >&2
  exit 1
fi

mkdir -p "$PROFILE/NativeMessagingHosts"
# Chrome for Testing reads native hosts from the user-data-dir, not from
# ~/Library/Application Support, when this profile is passed with --user-data-dir.
python3 - "$PROFILE/NativeMessagingHosts/com.mypass.chromehost.json" "${HOME}/Library/Application Support/MyPass/ChromeHost" <<'PY'
import json, sys
path, host = sys.argv[1], sys.argv[2]
manifest = {
    "allowed_origins": ["chrome-extension://hjijbabodfldconmhdcdphlbgaajkejn/"],
    "description": "MyPass native messaging host",
    "name": "com.mypass.chromehost",
    "path": host,
    "type": "stdio",
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
exec "$BIN" \
  --user-data-dir="$PROFILE" \
  --no-first-run \
  --no-default-browser-check \
  --disable-sync \
  --disable-features=DisableLoadExtensionCommandLineSwitch \
  --load-extension="${REPO_ROOT}/ChromeExtension" \
  "$@"
