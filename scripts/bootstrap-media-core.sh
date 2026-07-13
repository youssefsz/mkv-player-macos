#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_media-core-common.sh
source "$SCRIPT_DIR/_media-core-common.sh"

URL="${MEDIA_CORE_URL:-${MEDIA_CORE_BINARY_URL:-}}"
EXPECTED_SHA="${MEDIA_CORE_SHA256:-${MEDIA_CORE_BINARY_SHA256:-}}"
DESTINATION="$REPOSITORY_ROOT/Vendor/MediaCore.xcframework"
CACHE_DIR="${MEDIA_CORE_CACHE_DIR:-$HOME/Library/Caches/io.github.youssefsz.MKVPlayer/MediaCore}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Download and install a checksum-verified MediaCore.xcframework.

Options:
  --url URL             HTTPS URL for MediaCore.xcframework.zip
  --sha256 HASH         Expected SHA-256 of the zip archive
  --destination PATH    Install path (default: Vendor/MediaCore.xcframework)
  --cache-dir PATH      Download cache directory
  -h, --help            Show this help

The URL and checksum default to MEDIA_CORE_BINARY_URL and
MEDIA_CORE_BINARY_SHA256 in scripts/media-core.lock. They may also be supplied
through MEDIA_CORE_URL and MEDIA_CORE_SHA256.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)
      [[ $# -ge 2 ]] || die "--url requires a value"
      URL="$2"
      shift 2
      ;;
    --sha256)
      [[ $# -ge 2 ]] || die "--sha256 requires a value"
      EXPECTED_SHA="$2"
      shift 2
      ;;
    --destination)
      [[ $# -ge 2 ]] || die "--destination requires a path"
      DESTINATION="$2"
      shift 2
      ;;
    --cache-dir)
      [[ $# -ge 2 ]] || die "--cache-dir requires a path"
      CACHE_DIR="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "$URL" ]] || die "no MediaCore binary URL is pinned; build from source or pass --url"
[[ -n "$EXPECTED_SHA" ]] || die "no MediaCore binary checksum is pinned; pass --sha256"
[[ "$DESTINATION" == *.xcframework ]] || die "destination must end in .xcframework"

require_command curl
require_command ditto
require_command lipo
require_command otool
require_command shasum
require_command unzip
validate_https_url "$URL"
validate_sha256 "$EXPECTED_SHA"

archive="$CACHE_DIR/binaries/MediaCore-$EXPECTED_SHA.xcframework.zip"
download_verified "$URL" "$EXPECTED_SHA" "$archive"
validate_zip_entries "$archive"

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/MediaCore-bootstrap.XXXXXX")"
cleanup() {
  rm -rf "$temporary_directory"
}
trap cleanup EXIT

ditto -x -k "$archive" "$temporary_directory/extracted"

frameworks=()
while IFS= read -r -d '' framework; do
  frameworks+=("$framework")
done < <(find "$temporary_directory/extracted" -type d -name MediaCore.xcframework -print0)

[[ ${#frameworks[@]} -eq 1 ]] || die "archive must contain exactly one MediaCore.xcframework"
framework="${frameworks[0]}"
[[ -f "$framework/Info.plist" ]] || die "MediaCore.xcframework has no Info.plist"

binary_count=0
while IFS= read -r -d '' binary; do
  binary_count=$((binary_count + 1))
  for architecture in arm64 x86_64; do
    lipo "$binary" -verify_arch "$architecture" >/dev/null 2>&1 || \
      die "MediaCore.xcframework has no $architecture macOS slice"

    install_name="$(
      otool -arch "$architecture" -D "$binary" |
        tail -n +2 |
        head -n 1 |
        sed 's/^[[:space:]]*//'
    )"
    [[ "$install_name" == '@rpath/MediaCore.framework/Versions/A/MediaCore' ]] || \
      die "MediaCore has an unexpected $architecture install name: $install_name"
    if otool -arch "$architecture" -L "$binary" | tail -n +2 | \
      grep -vE '^[[:space:]]+(@rpath/MediaCore\.framework/|/usr/lib/|/System/Library/Frameworks/)' | \
      grep -q .; then
      die "MediaCore contains a non-system $architecture dynamic dependency"
    fi
  done
done < <(find "$framework" -type f -name MediaCore -print0)

[[ $binary_count -eq 1 ]] || die "MediaCore.xcframework must contain one universal framework binary"

parent="$(dirname "$DESTINATION")"
mkdir -p "$parent"
staged="$parent/.MediaCore.xcframework.staged.$$"
backup="$parent/.MediaCore.xcframework.backup.$$"
rm -rf "$staged" "$backup"
ditto "$framework" "$staged"

if [[ -e "$DESTINATION" ]]; then
  mv "$DESTINATION" "$backup"
fi
if ! mv "$staged" "$DESTINATION"; then
  [[ ! -e "$backup" ]] || mv "$backup" "$DESTINATION"
  die "could not install MediaCore.xcframework"
fi
rm -rf "$backup"

log "Installed verified MediaCore.xcframework at $DESTINATION"
