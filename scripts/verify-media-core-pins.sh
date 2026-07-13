#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_media-core-common.sh
source "$SCRIPT_DIR/_media-core-common.sh"

CACHE_DIR="${MEDIA_CORE_CACHE_DIR:-$HOME/Library/Caches/io.github.youssefsz.MKVPlayer/MediaCore}"

usage() {
  printf 'Usage: %s [--cache-dir PATH]\n' "$(basename "$0")"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
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

require_command awk
require_command curl
require_command git
require_command shasum
require_command tar
validate_lock_file

mkdir -p "$CACHE_DIR/downloads"

for component in "${MEDIA_CORE_COMPONENTS[@]}"; do
  url_variable="${component}_URL"
  sha_variable="${component}_SHA256"
  archive_variable="${component}_ARCHIVE"
  archive="$CACHE_DIR/downloads/${!archive_variable}"
  download_verified "${!url_variable}" "${!sha_variable}" "$archive"
  validate_archive_entries "$archive"
done

checkout="$CACHE_DIR/libplacebo-$LIBPLACEBO_COMMIT"
if [[ ! -d "$checkout/.git" ]]; then
  rm -rf "$checkout"
  log "Cloning pinned libplacebo source"
  git clone --quiet --no-checkout "$LIBPLACEBO_GIT_URL" "$checkout"
fi

git -C "$checkout" fetch --quiet --depth 1 origin "$LIBPLACEBO_COMMIT"
git -C "$checkout" -c advice.detachedHead=false checkout --quiet --detach "$LIBPLACEBO_COMMIT"
git -C "$checkout" submodule sync --quiet
git -C "$checkout" submodule update --init --depth 1 -- \
  3rdparty/glad \
  3rdparty/jinja \
  3rdparty/markupsafe \
  3rdparty/fast_float \
  3rdparty/Vulkan-Headers

[[ "$(git -C "$checkout" rev-parse HEAD)" == "$LIBPLACEBO_COMMIT" ]] || die "libplacebo commit mismatch"
[[ "$(git -C "$checkout/3rdparty/glad" rev-parse HEAD)" == "$LIBPLACEBO_GLAD_COMMIT" ]] || die "glad commit mismatch"
[[ "$(git -C "$checkout/3rdparty/jinja" rev-parse HEAD)" == "$LIBPLACEBO_JINJA_COMMIT" ]] || die "Jinja commit mismatch"
[[ "$(git -C "$checkout/3rdparty/markupsafe" rev-parse HEAD)" == "$LIBPLACEBO_MARKUPSAFE_COMMIT" ]] || die "MarkupSafe commit mismatch"
[[ "$(git -C "$checkout/3rdparty/fast_float" rev-parse HEAD)" == "$LIBPLACEBO_FAST_FLOAT_COMMIT" ]] || die "fast_float commit mismatch"
[[ "$(git -C "$checkout/3rdparty/Vulkan-Headers" rev-parse HEAD)" == "$LIBPLACEBO_VULKAN_HEADERS_COMMIT" ]] || die "Vulkan-Headers commit mismatch"

for repository in \
  "$checkout" \
  "$checkout/3rdparty/glad" \
  "$checkout/3rdparty/jinja" \
  "$checkout/3rdparty/markupsafe" \
  "$checkout/3rdparty/fast_float" \
  "$checkout/3rdparty/Vulkan-Headers"; do
  if [[ -n "$(git -C "$repository" status --porcelain --untracked-files=all)" ]]; then
    die "verified Git source has local modifications: $repository"
  fi
done

log "All MediaCore source pins are present and verified"
