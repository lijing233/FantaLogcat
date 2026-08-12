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

"$creator" "$fixture_app" "$fixture_dmg"
hdiutil verify "$fixture_dmg" >/dev/null
hdiutil attach "$fixture_dmg" -readonly -nobrowse -mountpoint "$mount_point" -quiet
is_mounted=true

[ -d "$mount_point/FantaLogcat.app" ]
[ -x "$mount_point/FantaLogcat.app/Contents/MacOS/FantaLogcat" ]
[ -L "$mount_point/Applications" ]
[ "$(readlink "$mount_point/Applications")" = /Applications ]

printf '%s\n' 'DMG fixture checks passed'
