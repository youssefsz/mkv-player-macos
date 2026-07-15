#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") --app APP --output DMG --create-dmg TOOL

Create the branded, drag-to-Applications MKV Player disk image.
EOF
}

app=""
output=""
create_dmg=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      [[ $# -ge 2 ]] || { usage; exit 64; }
      app="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || { usage; exit 64; }
      output="$2"
      shift 2
      ;;
    --create-dmg)
      [[ $# -ge 2 ]] || { usage; exit 64; }
      create_dmg="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage
      printf 'Unknown argument: %s\n' "$1" >&2
      exit 64
      ;;
  esac
done

[[ -d "$app" && "${app##*.}" == "app" ]] || {
  printf 'App bundle does not exist: %s\n' "$app" >&2
  exit 1
}
[[ -n "$output" ]] || { usage; exit 64; }
[[ -x "$create_dmg" ]] || {
  printf 'create-dmg is not executable: %s\n' "$create_dmg" >&2
  exit 1
}

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/MKVPlayer-dmg.XXXXXX")"
cleanup() {
  rm -rf "$temporary_directory"
}
trap cleanup EXIT

staging_directory="$temporary_directory/staging"
assets_directory="$temporary_directory/assets"
mkdir -p "$staging_directory" "$(dirname "$output")"
ditto "$app" "$staging_directory/MKV Player.app"
"$SCRIPT_DIR/render-dmg-assets.sh" "$assets_directory"

rm -f "$output"
"$create_dmg" \
  --volname 'MKV Player' \
  --volicon "$assets_directory/MKVPlayer.icns" \
  --background "$assets_directory/background.tiff" \
  --window-pos 200 120 \
  --window-size 660 400 \
  --icon-size 112 \
  --text-size 13 \
  --icon 'MKV Player.app' 165 235 \
  --hide-extension 'MKV Player.app' \
  --app-drop-link 495 235 \
  --no-internet-enable \
  --format UDZO \
  --filesystem HFS+ \
  "$output" \
  "$staging_directory"

hdiutil verify "$output" >/dev/null
printf 'Created branded disk image: %s\n' "$output"
