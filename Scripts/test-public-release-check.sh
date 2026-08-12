#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
checker="$script_dir/check-public-release.sh"
temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/fantalogcat-public-release.XXXXXX")

cleanup() {
  rm -rf "$temporary_root"
}

trap cleanup EXIT HUP INT TERM

expect_success() {
  case_name=$1
  shift

  if "$@"; then
    return 0
  fi

  printf 'failed case: %s\n' "$case_name" >&2
  return 1
}

expect_failure_containing() {
  case_name=$1
  expected_output=$2
  shift
  shift

  output_file="$temporary_root/$case_name.output"

  if "$@" >"$output_file" 2>&1; then
    printf 'failed case: %s\n' "$case_name" >&2
    return 1
  fi

  if ! grep -F "$expected_output" "$output_file" >/dev/null; then
    printf 'failed case: %s\n' "$case_name" >&2
    return 1
  fi
}

create_source_fixture() {
  source_root=$1
  include_readme=$2

  mkdir -p "$source_root"
  git -C "$source_root" init -q

  for document in LICENSE NOTICE CONTRIBUTING.md SECURITY.md CODE_OF_CONDUCT.md docs/RELEASE_CHECKLIST.md; do
    mkdir -p "$(dirname "$source_root/$document")"
    printf '%s\n' "$document" > "$source_root/$document"
  done

  if [ "$include_readme" = yes ]; then
    printf '%s\n' 'README' > "$source_root/README.md"
  fi

  git -C "$source_root" add .
}

create_app_fixture() {
  app_path=$1

  mkdir -p "$app_path/Contents/MacOS"
  : > "$app_path/Contents/MacOS/FantaLogcat"
  chmod +x "$app_path/Contents/MacOS/FantaLogcat"
}

fixtures_root="$temporary_root/public release fixtures"
clean_source="$fixtures_root/clean source"
source_with_team_config="$fixtures_root/source with team config"
source_with_tracked_team_config="$fixtures_root/source with tracked team config"
source_without_readme="$fixtures_root/source without readme"
clean_app="$fixtures_root/clean app/FantaLogcat.app"
app_with_team_config="$fixtures_root/app with team config/FantaLogcat.app"
app_without_executable="$fixtures_root/app without executable/FantaLogcat.app"
app_with_non_executable="$fixtures_root/app with non executable/FantaLogcat.app"

create_source_fixture "$clean_source" yes
create_source_fixture "$source_with_team_config" yes
mkdir -p "$source_with_team_config/Config"
printf '%s\n' 'private' > "$source_with_team_config/Config/TeamConfig.json"
git -C "$source_with_team_config" add Config/TeamConfig.json
create_source_fixture "$source_with_tracked_team_config" yes
mkdir -p "$source_with_tracked_team_config/private settings/nested"
printf '%s\n' 'private' > "$source_with_tracked_team_config/private settings/nested/TeamConfig.json"
git -C "$source_with_tracked_team_config" add 'private settings/nested/TeamConfig.json'
create_source_fixture "$source_without_readme" no

create_app_fixture "$clean_app"
create_app_fixture "$app_with_team_config"
mkdir -p "$app_with_team_config/Contents/Resources/Config"
printf '%s\n' 'private' > "$app_with_team_config/Contents/Resources/Config/TeamConfig.json"
mkdir -p "$app_without_executable/Contents/MacOS"
create_app_fixture "$app_with_non_executable"
chmod -x "$app_with_non_executable/Contents/MacOS/FantaLogcat"

expect_success clean_source_and_app env SOURCE_ROOT="$clean_source" APP_PATH="$clean_app" "$checker"
expect_failure_containing team_config_in_source 'private source configuration exists: Config/TeamConfig.json' env SOURCE_ROOT="$source_with_team_config" "$checker"
expect_failure_containing tracked_team_config_in_source 'tracked private configuration:' env SOURCE_ROOT="$source_with_tracked_team_config" "$checker"
expect_failure_containing team_config_in_bundle 'private app configuration:' env SOURCE_ROOT="$clean_source" APP_PATH="$app_with_team_config" "$checker"
expect_failure_containing missing_required_document 'missing required document: README.md' env SOURCE_ROOT="$source_without_readme" "$checker"
expect_failure_containing missing_app_executable 'app executable is missing or not executable: Contents/MacOS/FantaLogcat' env SOURCE_ROOT="$clean_source" APP_PATH="$app_without_executable" "$checker"
expect_failure_containing non_executable_app 'app executable is missing or not executable: Contents/MacOS/FantaLogcat' env SOURCE_ROOT="$clean_source" APP_PATH="$app_with_non_executable" "$checker"

printf '%s\n' 'public release check fixtures passed'
