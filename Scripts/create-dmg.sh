#!/bin/sh

set -eu

app_path=${1:?usage: create-dmg.sh APP_PATH OUTPUT_DMG}
output_dmg=${2:?usage: create-dmg.sh APP_PATH OUTPUT_DMG}
volume_name=${VOLUME_NAME:-FantaLogcat Installer}
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

case "$volume_name" in
  ''|*/*)
    printf 'DMG creation failed: invalid volume name: %s\n' "$volume_name" >&2
    exit 1
    ;;
esac

[ -d "$app_path" ] || {
  printf 'DMG creation failed: app does not exist: %s\n' "$app_path" >&2
  exit 1
}

[ -x "$app_path/Contents/MacOS/FantaLogcat" ] || {
  printf 'DMG creation failed: app executable is missing or not executable\n' >&2
  exit 1
}

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/fantalogcat-dmg-create.XXXXXX")
mount_point="/Volumes/$volume_name"
is_mounted=false

cleanup() {
  if [ "$is_mounted" = true ]; then
    hdiutil detach "$mount_point" -quiet || true
  fi
  rm -rf "$temporary_root"
}

trap cleanup EXIT HUP INT TERM

staging_dir="$temporary_root/$volume_name"
background_path="$staging_dir/.background/background.png"
read_write_dmg="$temporary_root/FantaLogcat-read-write.dmg"

mkdir -p "$staging_dir" "$(dirname "$output_dmg")"
ditto "$app_path" "$staging_dir/FantaLogcat.app"
ln -s /Applications "$staging_dir/Applications"
swift "$script_dir/create-dmg-background.swift" "$background_path"

rm -f "$output_dmg"
[ ! -e "$mount_point" ] || {
  printf 'DMG creation failed: eject the existing “%s” volume and retry\n' "$volume_name" >&2
  exit 1
}

hdiutil create \
  -quiet \
  -volname "$volume_name" \
  -srcfolder "$staging_dir" \
  -fs HFS+ \
  -format UDRW \
  -ov \
  "$read_write_dmg"

hdiutil attach \
  "$read_write_dmg" \
  -readwrite \
  -noverify \
  -noautoopen \
  -mountpoint "$mount_point" \
  -quiet
is_mounted=true

chflags hidden "$mount_point/.background"

osascript - "$volume_name" "$mount_point" <<'APPLESCRIPT'
on run arguments
  set volumeName to item 1 of arguments
  set mountPath to item 2 of arguments
  set backgroundFile to POSIX file (mountPath & "/.background/background.png") as alias

  tell application "Finder"
    tell disk volumeName
      open
      set dmgWindow to container window
      set current view of dmgWindow to icon view
      set toolbar visible of dmgWindow to false
      set statusbar visible of dmgWindow to false
      set pathbar visible of dmgWindow to false
      set sidebar width of dmgWindow to 0
      set bounds of dmgWindow to {160, 120, 920, 560}

      set iconOptions to icon view options of dmgWindow
      set arrangement of iconOptions to not arranged
      set icon size of iconOptions to 92
      set text size of iconOptions to 13
      set background picture of iconOptions to backgroundFile

      set position of item "FantaLogcat.app" to {195, 230}
      set position of item "Applications" to {565, 230}

      update without registering applications
      delay 2
      close
      delay 2
    end tell
  end tell
end run
APPLESCRIPT

sync
hdiutil detach "$mount_point" -quiet
is_mounted=false

hdiutil convert \
  "$read_write_dmg" \
  -quiet \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$output_dmg"

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
