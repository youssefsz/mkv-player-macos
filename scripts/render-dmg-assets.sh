#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  printf 'Usage: %s OUTPUT_DIRECTORY\n' "$(basename "$0")" >&2
}

if [[ $# -ne 1 ]]; then
  usage
  exit 64
fi

for command in iconutil sips tiffutil; do
  if ! command -v "$command" >/dev/null 2>&1; then
    printf 'Required command is unavailable: %s\n' "$command" >&2
    exit 1
  fi
done

output_directory="$1"
background_source="$REPOSITORY_ROOT/packaging/dmg/background.svg"
icon_source="$REPOSITORY_ROOT/App/MKVPlayer/Resources/AppIcon.svg"

[[ -f "$background_source" ]] || {
  printf 'DMG background source is missing: %s\n' "$background_source" >&2
  exit 1
}
[[ -f "$icon_source" ]] || {
  printf 'App icon source is missing: %s\n' "$icon_source" >&2
  exit 1
}

mkdir -p "$output_directory"

background_1x="$output_directory/background.png"
background_2x="$output_directory/background@2x.png"
background_tiff="$output_directory/background.tiff"

sips -s format png "$background_source" --out "$background_2x" >/dev/null
sips -z 400 660 "$background_2x" --out "$background_1x" >/dev/null

background_1x_dimensions="$(sips -g pixelWidth -g pixelHeight "$background_1x")"
background_2x_dimensions="$(sips -g pixelWidth -g pixelHeight "$background_2x")"
grep -q 'pixelWidth: 660' <<<"$background_1x_dimensions"
grep -q 'pixelHeight: 400' <<<"$background_1x_dimensions"
grep -q 'pixelWidth: 1320' <<<"$background_2x_dimensions"
grep -q 'pixelHeight: 800' <<<"$background_2x_dimensions"
tiffutil -cathidpicheck "$background_1x" "$background_2x" -out "$background_tiff" >/dev/null

iconset="$output_directory/MKVPlayer.iconset"
icon_1024="$output_directory/AppIcon-1024.png"
mkdir -p "$iconset"
sips -s format png "$icon_source" --out "$icon_1024" >/dev/null

render_icon() {
  local pixel_size="$1"
  local destination="$2"
  sips -z "$pixel_size" "$pixel_size" "$icon_1024" --out "$destination" >/dev/null
}

render_icon 16 "$iconset/icon_16x16.png"
render_icon 32 "$iconset/icon_16x16@2x.png"
render_icon 32 "$iconset/icon_32x32.png"
render_icon 64 "$iconset/icon_32x32@2x.png"
render_icon 128 "$iconset/icon_128x128.png"
render_icon 256 "$iconset/icon_128x128@2x.png"
render_icon 256 "$iconset/icon_256x256.png"
render_icon 512 "$iconset/icon_256x256@2x.png"
render_icon 512 "$iconset/icon_512x512.png"
ditto "$icon_1024" "$iconset/icon_512x512@2x.png"
iconutil -c icns "$iconset" -o "$output_directory/MKVPlayer.icns"

printf 'Rendered Retina DMG artwork in %s\n' "$output_directory"
