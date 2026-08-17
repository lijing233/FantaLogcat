#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
creator="$script_dir/create-dmg.sh"
temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/fantalogcat-dmg.XXXXXX")
mount_point="$temporary_root/mounted"
is_mounted=false

cleanup() {
  if [ "$is_mounted" = true ]; then
    hdiutil detach "$mount_point" -quiet || true
  fi
  rm -rf "$temporary_root"
}

trap cleanup EXIT HUP INT TERM

fixture_app="$temporary_root/FantaLogcat.app"
fixture_dmg="$temporary_root/FantaLogcat.dmg"

mkdir -p "$fixture_app/Contents/MacOS" "$mount_point"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$fixture_app/Contents/MacOS/FantaLogcat"
chmod +x "$fixture_app/Contents/MacOS/FantaLogcat"

if VOLUME_NAME='../unsafe' "$creator" "$fixture_app" "$fixture_dmg" >/dev/null 2>&1; then
  printf '%s\n' 'DMG fixture check failed: unsafe volume name was accepted' >&2
  exit 1
fi

"$creator" "$fixture_app" "$fixture_dmg"
hdiutil verify "$fixture_dmg" >/dev/null
hdiutil attach "$fixture_dmg" -readonly -nobrowse -mountpoint "$mount_point" -quiet
is_mounted=true

[ -d "$mount_point/FantaLogcat.app" ]
[ -x "$mount_point/FantaLogcat.app/Contents/MacOS/FantaLogcat" ]
[ -L "$mount_point/Applications" ]
[ "$(readlink "$mount_point/Applications")" = /Applications ]
[ -f "$mount_point/打开隐私与安全性.webloc" ]
[ "$(/usr/libexec/PlistBuddy -c 'Print :URL' "$mount_point/打开隐私与安全性.webloc")" = 'x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension' ]
[ -f "$mount_point/.metadata_never_index" ] || {
  printf '%s\n' 'DMG fixture check failed: Spotlight exclusion marker is missing' >&2
  exit 1
}
[ -s "$mount_point/.background/background.png" ] || {
  printf '%s\n' 'DMG fixture check failed: background image is missing' >&2
  exit 1
}
[ "$(sips -g pixelWidth "$mount_point/.background/background.png" | awk '/pixelWidth/ { print $2 }')" = 760 ]
[ "$(sips -g pixelHeight "$mount_point/.background/background.png" | awk '/pixelHeight/ { print $2 }')" = 440 ]
[ -s "$mount_point/.DS_Store" ] || {
  printf '%s\n' 'DMG fixture check failed: Finder layout is missing' >&2
  exit 1
}

printf '%s\n' 'DMG fixture checks passed'
