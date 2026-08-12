#!/bin/sh

set -eu

app_path=${1:?usage: create-dmg.sh APP_PATH OUTPUT_DMG}
output_dmg=${2:?usage: create-dmg.sh APP_PATH OUTPUT_DMG}
volume_name=${VOLUME_NAME:-FantaLogcat}

[ -d "$app_path" ] || {
  printf 'DMG creation failed: app does not exist: %s\n' "$app_path" >&2
  exit 1
}

[ -x "$app_path/Contents/MacOS/FantaLogcat" ] || {
  printf 'DMG creation failed: app executable is missing or not executable\n' >&2
  exit 1
}

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/fantalogcat-dmg-create.XXXXXX")

cleanup() {
  rm -rf "$temporary_root"
}

trap cleanup EXIT HUP INT TERM

staging_dir="$temporary_root/$volume_name"
mkdir -p "$staging_dir" "$(dirname "$output_dmg")"
ditto "$app_path" "$staging_dir/FantaLogcat.app"
ln -s /Applications "$staging_dir/Applications"

rm -f "$output_dmg"
hdiutil create \
  -quiet \
  -volname "$volume_name" \
  -srcfolder "$staging_dir" \
  -format UDZO \
  -ov \
  "$output_dmg"

verify_attempt=1
while ! hdiutil verify "$output_dmg" >/dev/null 2>&1; do
  if [ "$verify_attempt" -ge 5 ]; then
    printf 'DMG creation failed: image verification did not succeed after %s attempts\n' "$verify_attempt" >&2
    exit 1
  fi

  sleep 1
  verify_attempt=$((verify_attempt + 1))
done

printf 'Created DMG: %s\n' "$output_dmg"
