#!/usr/bin/env bash
# Quit every running MyPass, remove older com.mypass.app bundles, and open this build.
# A second copy is stopped so Launch Services cannot keep an old DerivedData app alive.
set -euo pipefail

APP="${1:-}"
BUNDLE_ID="com.mypass.app"
PROCESS_PATTERN='MyPass\.app/Contents/MacOS/MyPass'
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

if [[ -z "$APP" || ! -d "$APP" ]]; then
  echo "Usage: scripts/launch-mypass.sh /path/to/MyPass.app" >&2
  exit 1
fi

canon() {
  python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

bundle_id_of() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null || true
}

mypass_pids() {
  local pids
  pids=$(pgrep -f "$PROCESS_PATTERN" || true)
  printf '%s\n' "$pids" | grep -v -x "$$" || true
}

stop_running_mypass() {
  local pids pids_before waited
  pids=$(mypass_pids)
  [[ -z "$pids" ]] && return 0
  pids_before="$pids"
  for pid in $pids; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  waited=0
  while (( waited < 5000 )); do
    pids=$(mypass_pids)
    [[ -z "$pids" ]] && break
    sleep 0.2
    waited=$(( waited + 200 ))
  done
  if [[ -n "$pids" ]]; then
    for pid in $pids; do
      kill -KILL "$pid" 2>/dev/null || true
    done
    sleep 0.2
    pids=$(mypass_pids)
  fi
  if [[ -n "$pids" ]]; then
    echo "Error: could not stop running MyPass instance(s): $pids" >&2
    echo "Inspect with: ps -p $pids -o pid,ppid,command" >&2
    exit 1
  fi
  echo "Stopped running MyPass (pid $(printf '%s' "$pids_before" | tr '\n' ' ' | sed 's/ *$//'))"
}

APP="$(canon "$APP")"
if [[ "$(basename "$APP")" != "MyPass.app" || "$(bundle_id_of "$APP")" != "$BUNDLE_ID" ]]; then
  echo "Error: $APP is not a $BUNDLE_ID bundle." >&2
  exit 1
fi

stop_running_mypass

removed_list=""
consider_bundle() {
  local candidate="$1"
  [[ -d "$candidate" ]] || return 0
  candidate="$(canon "$candidate")"
  [[ "$candidate" == "$APP" ]] && return 0
  [[ "$(basename "$candidate")" == "MyPass.app" ]] || return 0
  [[ "$(bundle_id_of "$candidate")" == "$BUNDLE_ID" ]] || return 0
  case "
$removed_list
" in
    *"
$candidate
"*) return 0 ;;
  esac
  if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -u "$candidate" || true
  fi
  rm -rf "$candidate"
  removed_list="${removed_list}
${candidate}"
  echo "Removed old MyPass: $candidate"
}

while IFS= read -r found; do
  [[ -n "$found" ]] && consider_bundle "$found"
done < <(mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'" 2>/dev/null || true)
while IFS= read -r found; do
  [[ -n "$found" ]] && consider_bundle "$found"
done < <(find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 6 -type d -name 'MyPass.app' -path '*/Build/Products/*' -print 2>/dev/null || true)

touch "$APP"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$APP" || true
fi

open "$APP"

waited=0
while (( waited < 8000 )); do
  pids=$(mypass_pids)
  [[ -n "$pids" ]] && break
  sleep 0.2
  waited=$(( waited + 200 ))
done

if [[ -z "${pids:-}" ]]; then
  echo "Error: MyPass did not start from $APP" >&2
  exit 1
fi

for pid in $pids; do
  command=$(ps -p "$pid" -o command= 2>/dev/null || true)
  case "$command" in
    "$APP"/*) ;;
    *)
      kill -TERM "$pid" 2>/dev/null || true
      echo "Stopped extra MyPass pid $pid"
      ;;
  esac
done

sleep 0.3
pids=$(mypass_pids)
extra=""
for pid in $pids; do
  command=$(ps -p "$pid" -o command= 2>/dev/null || true)
  case "$command" in
    "$APP"/*) ;;
    *) extra="$extra $pid" ;;
  esac
done
if [[ -n "${extra// /}" ]]; then
  echo "Error: another MyPass is still running:$extra" >&2
  exit 1
fi

count=0
for pid in $pids; do
  count=$(( count + 1 ))
done
if (( count > 1 )); then
  keep=""
  for pid in $pids; do
    if [[ -z "$keep" ]]; then
      keep="$pid"
    else
      kill -TERM "$pid" 2>/dev/null || true
      echo "Stopped duplicate MyPass pid $pid"
    fi
  done
fi

echo "Launched $APP"
