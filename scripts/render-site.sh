#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "Usage: $0 VERSION DOWNLOAD_URL RELEASE_URL OUTPUT_DIRECTORY" >&2
  exit 64
fi

version="$1"
download_url="$2"
release_url="$3"
output_directory="$4"
repository_url="https://github.com/youssefsz/mkv-player-macos"
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Site version must have the form MAJOR.MINOR.PATCH" >&2
  exit 1
fi
if [[ "$download_url" != "$repository_url/releases/download/v$version/"*.dmg ]]; then
  echo "Site download URL is not the DMG for v$version" >&2
  exit 1
fi
if [[ "$release_url" != "$repository_url/releases/tag/v$version" ]]; then
  echo "Site release URL does not match v$version" >&2
  exit 1
fi

mkdir -p "$output_directory"
ditto "$project_root/site/index.html" "$output_directory/index.html"
ditto "$project_root/site/styles.css" "$output_directory/styles.css"
ditto "$project_root/site/site.js" "$output_directory/site.js"
ditto "$project_root/site/product-tour.mp4" "$output_directory/product-tour.mp4"
ditto "$project_root/site/product-tour-poster.jpg" "$output_directory/product-tour-poster.jpg"
ditto "$project_root/site/product-tour-poster.jpg" "$output_directory/app-screenshot.png"
ditto \
  "$project_root/App/MKVPlayer/Resources/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" \
  "$output_directory/icon.png"

SITE_VERSION="$version" \
SITE_DOWNLOAD_URL="$download_url" \
SITE_RELEASE_URL="$release_url" \
  perl -0pi -e '
    s/__SITE_VERSION__/$ENV{SITE_VERSION}/g;
    s/__SITE_DOWNLOAD_URL__/$ENV{SITE_DOWNLOAD_URL}/g;
    s/__SITE_RELEASE_URL__/$ENV{SITE_RELEASE_URL}/g;
  ' "$output_directory/index.html"

if grep -Eq '__SITE_[A-Z_]+__' "$output_directory/index.html"; then
  echo "Rendered site contains an unresolved release placeholder" >&2
  exit 1
fi

touch "$output_directory/.nojekyll"
