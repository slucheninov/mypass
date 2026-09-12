#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

UPSTREAM_URL="https://github.com/apple/password-manager-resources.git"
UPSTREAM_DATA_FILE="quirks/password-rules.json"
UPSTREAM_LICENSE_FILE="LICENSE.md"

DATA_TARGET="$REPO_ROOT/Packages/MyPassKit/Sources/MyPassKit/Resources/password-rules.json"
PROVENANCE_TARGET="$REPO_ROOT/Packages/MyPassKit/Sources/MyPassKit/Resources/PASSWORD_RULES_PROVENANCE.md"

require_command() {
  local cmd="$1"
  local hint="${2:-}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: required command '$cmd' not found." >&2
    [[ -n "$hint" ]] && echo "$hint" >&2
    exit 1
  fi
}

require_command git
# python3, not jq: this repo already relies on python3 for JSON handling
# elsewhere (scripts/setup-chrome-extension.sh writes the native messaging
# manifest via `python3 -c "import json; ..."`), so reusing it here avoids
# introducing a second JSON tool as a preflight dependency.
require_command python3

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "Cloning $UPSTREAM_URL (shallow)..."
git clone --depth 1 "$UPSTREAM_URL" "$WORK_DIR/repo" >/dev/null

COMMIT_SHA="$(git -C "$WORK_DIR/repo" rev-parse HEAD)"
RETRIEVAL_DATE="$(date -u +%Y-%m-%d)"

if [[ ! -f "$WORK_DIR/repo/$UPSTREAM_DATA_FILE" ]]; then
  echo "Error: $UPSTREAM_DATA_FILE not found at $UPSTREAM_URL@$COMMIT_SHA -- upstream layout may have changed." >&2
  exit 1
fi

ENTRY_COUNT="$(python3 -c "
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    data = json.load(f)
print(len(data))
" "$WORK_DIR/repo/$UPSTREAM_DATA_FILE")"

if [[ "$ENTRY_COUNT" -lt 1 ]]; then
  echo "Error: fetched password-rules.json has zero entries -- refusing to vendor an empty snapshot." >&2
  exit 1
fi

# Committed as-is, no reformatting -- see PASSWORD_RULES_PROVENANCE.md for
# why: it keeps a future `git diff` against upstream readable.
cp "$WORK_DIR/repo/$UPSTREAM_DATA_FILE" "$DATA_TARGET"

cat > "$PROVENANCE_TARGET" <<EOF
# Vendored: Apple password-manager-resources (quirks/password-rules.json)

- Upstream: https://github.com/apple/password-manager-resources
- Vendored file: quirks/password-rules.json
- Commit: $COMMIT_SHA
- Retrieved on: $RETRIEVAL_DATE
- Entry count at that commit: $ENTRY_COUNT

The vendored JSON is committed as-is, with no reformatting, so a future
\`git diff\` against upstream stays readable. Regenerate with
\`scripts/update-password-rules.sh\` -- this file and \`password-rules.json\`
are always rewritten together, in the same run, so they can never
independently drift out of sync.

## Licence

Copied verbatim from upstream's \`LICENSE.md\` at the commit above:

EOF

cat "$WORK_DIR/repo/$UPSTREAM_LICENSE_FILE" >> "$PROVENANCE_TARGET"

echo "Updated $DATA_TARGET ($ENTRY_COUNT entries) and $PROVENANCE_TARGET at commit $COMMIT_SHA."
