#!/bin/sh

set -eu

fail() {
  printf 'app launch smoke test failed: %s\n' "$1" >&2
  if [ -s "$log_file" ]; then
    sed -n '1,120p' "$log_file" >&2
  fi
  exit 1
}

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
source_root=$(CDPATH= cd "$script_dir/.." && pwd)
app_path=${1:-"$source_root/.build/releases/FantaLogcat.app"}
executable="$app_path/Contents/MacOS/FantaLogcat"
log_file=$(mktemp "${TMPDIR:-/tmp}/fantalogcat-launch.XXXXXX")
pid=

cleanup() {
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  rm -f "$log_file"
}
trap cleanup EXIT HUP INT TERM

[ -x "$executable" ] || fail "app executable is missing: $executable"

"$executable" --ui-testing-search >"$log_file" 2>&1 &
pid=$!
sleep 3

kill -0 "$pid" 2>/dev/null || fail 'the app terminated during startup'

printf 'app launch smoke test passed: %s\n' "$app_path"
