#!/bin/sh

set -eu

fail() {
  printf 'appcast generation failed: %s\n' "$1" >&2
  exit 1
}

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
source_root=$(CDPATH= cd "$script_dir/.." && pwd)
archive=${1:-"$source_root/.build/releases/FantaLogcat-macos-arm64.zip"}
release_notes=${2:-}
sparkle_tools="$source_root/.build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"
generate_appcast="$sparkle_tools/generate_appcast"
app="$source_root/.build/releases/FantaLogcat.app"

[ -x "$generate_appcast" ] || fail "Sparkle generate_appcast tool is unavailable; run make build first"
[ -s "$archive" ] || fail "update archive is missing: $archive"
[ -d "$app" ] || fail "release app is missing: $app"

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")
[ -n "$version" ] || fail 'CFBundleShortVersionString is empty'
[ -n "$build" ] || fail 'CFBundleVersion is empty'

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/fantalogcat-appcast.XXXXXX")
cleanup() {
  rm -rf "$temporary_root"
}
trap cleanup EXIT HUP INT TERM

archive_name=$(basename "$archive")
cp "$archive" "$temporary_root/$archive_name"

if [ -n "$release_notes" ]; then
  [ -s "$release_notes" ] || fail "release notes are missing: $release_notes"
  notes_base=${archive_name%.*}
  cp "$release_notes" "$temporary_root/$notes_base.md"
fi

"$generate_appcast" \
  --download-url-prefix "https://github.com/lijing233/FantaLogcat/releases/download/v$version/" \
  --link 'https://lijing233.github.io/FantaLogcat/' \
  --embed-release-notes \
  --maximum-versions 1 \
  --maximum-deltas 0 \
  -o "$temporary_root/appcast.xml" \
  "$temporary_root"

cp "$temporary_root/appcast.xml" "$source_root/docs/appcast.xml"
grep -F "<sparkle:version>$build</sparkle:version>" "$source_root/docs/appcast.xml" >/dev/null || fail 'generated appcast has the wrong build number'
grep -F "<sparkle:shortVersionString>$version</sparkle:shortVersionString>" "$source_root/docs/appcast.xml" >/dev/null || fail 'generated appcast has the wrong version'
grep -F 'sparkle:edSignature=' "$source_root/docs/appcast.xml" >/dev/null || fail 'generated appcast is not EdDSA signed'

printf 'Generated signed appcast for FantaLogcat %s (%s): %s\n' "$version" "$build" "$source_root/docs/appcast.xml"
