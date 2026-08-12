#!/bin/sh

set -eu

fail() {
  printf 'public release check failed: %s\n' "$1" >&2
  exit 1
}

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
source_root=${SOURCE_ROOT:-$(CDPATH= cd "$script_dir/.." && pwd)}

[ -d "$source_root" ] || fail "source root is not a directory: $source_root"

for required_document in README.md LICENSE NOTICE CONTRIBUTING.md SECURITY.md CODE_OF_CONDUCT.md docs/RELEASE_CHECKLIST.md; do
  [ -f "$source_root/$required_document" ] || fail "missing required document: $required_document"
done

[ ! -e "$source_root/Config/TeamConfig.json" ] || fail 'private source configuration exists: Config/TeamConfig.json'

if ! git -C "$source_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  fail "source root is not a Git work tree: $source_root"
fi

tracked_private_paths=$(git -C "$source_root" ls-files -- ':(glob)**/TeamConfig.json')
if [ -n "$tracked_private_paths" ]; then
  printf 'public release check failed: tracked private configuration:\n%s\n' "$tracked_private_paths" >&2
  exit 1
fi

if [ -n "${APP_PATH:-}" ]; then
  [ -d "$APP_PATH" ] || fail "app path is not a directory: $APP_PATH"
  [ -f "$APP_PATH/Contents/MacOS/FantaLogcat" ] && [ -x "$APP_PATH/Contents/MacOS/FantaLogcat" ] || fail 'app executable is missing or not executable: Contents/MacOS/FantaLogcat'

  if app_private_paths=$(find "$APP_PATH" -name TeamConfig.json -print); then
    if [ -n "$app_private_paths" ]; then
      printf 'public release check failed: private app configuration:\n%s\n' "$app_private_paths" >&2
      exit 1
    fi
  else
    fail "could not scan app path: $APP_PATH"
  fi
fi

printf '%s\n' 'public release checks passed'
