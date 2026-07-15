#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# This variable is consumed by the scripts that source this shared file.
# shellcheck disable=SC2034
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCK_FILE="$SCRIPT_DIR/media-core.lock"

if [[ ! -f "$LOCK_FILE" ]]; then
  printf 'error: lock file is missing: %s\n' "$LOCK_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$LOCK_FILE"

log() {
  printf '==> %s\n' "$*"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

validate_sha256() {
  [[ "$1" =~ ^[0-9a-f]{64}$ ]] || die "invalid SHA-256 value: $1"
}

validate_https_url() {
  [[ "$1" == https://* ]] || die "only HTTPS downloads are accepted: $1"
}

validate_lock_file() {
  [[ "${MEDIA_CORE_LOCK_FORMAT:-}" == "1" ]] || die "unsupported media-core lock format"
  [[ "${MEDIA_CORE_MINIMUM_MACOS:-}" =~ ^[0-9]+\.[0-9]+$ ]] || die "invalid minimum macOS version"

  local component variable value url_variable sha_variable
  for component in "${MEDIA_CORE_COMPONENTS[@]}"; do
    for variable in URL SHA256 ARCHIVE DIRECTORY VERSION; do
      value="${component}_${variable}"
      [[ -n "${!value:-}" ]] || die "missing $value in $LOCK_FILE"
    done
    url_variable="${component}_URL"
    sha_variable="${component}_SHA256"
    validate_https_url "${!url_variable}"
    validate_sha256 "${!sha_variable}"
  done

  validate_https_url "$LIBPLACEBO_GIT_URL"
  for value in \
    "$LIBPLACEBO_COMMIT" \
    "$LIBPLACEBO_GLAD_COMMIT" \
    "$LIBPLACEBO_JINJA_COMMIT" \
    "$LIBPLACEBO_MARKUPSAFE_COMMIT" \
    "$LIBPLACEBO_FAST_FLOAT_COMMIT" \
    "$LIBPLACEBO_VULKAN_HEADERS_COMMIT"; do
    [[ "$value" =~ ^[0-9a-f]{40}$ ]] || die "invalid libplacebo Git commit: $value"
  done

  validate_https_url "$SPARKLE_TOOLS_URL"
  validate_sha256 "$SPARKLE_TOOLS_SHA256"
}

download_verified() {
  local url="$1"
  local expected_sha="$2"
  local destination="$3"
  local partial="${destination}.partial.$$"
  local actual_sha

  validate_https_url "$url"
  validate_sha256 "$expected_sha"
  mkdir -p "$(dirname "$destination")"

  if [[ -f "$destination" ]]; then
    actual_sha="$(sha256_file "$destination")"
    if [[ "$actual_sha" == "$expected_sha" ]]; then
      log "Using verified cache entry $(basename "$destination")"
      return
    fi
    log "Discarding cache entry with an invalid checksum: $(basename "$destination")"
    rm -f "$destination"
  fi

  rm -f "$partial"
  log "Downloading $url"
  if ! curl --fail --location --proto '=https' --tlsv1.2 \
    --retry 3 --retry-delay 2 --silent --show-error \
    --output "$partial" "$url"; then
    rm -f "$partial"
    die "download failed: $url"
  fi

  actual_sha="$(sha256_file "$partial")"
  if [[ "$actual_sha" != "$expected_sha" ]]; then
    rm -f "$partial"
    die "checksum mismatch for $url (expected $expected_sha, got $actual_sha)"
  fi

  mv "$partial" "$destination"
}

validate_archive_entries() {
  local archive="$1"
  local entry listing

  if ! listing="$(tar -tf "$archive")"; then
    die "could not read source archive: $archive"
  fi

  while IFS= read -r entry; do
    case "$entry" in
      /*|../*|*/../*|*/..|..|*\\*)
        die "archive contains an unsafe path: $entry"
        ;;
    esac
  done <<<"$listing"
}

validate_zip_entries() {
  local archive="$1"
  local entry listing

  if ! listing="$(unzip -Z1 "$archive")"; then
    die "could not read zip archive: $archive"
  fi

  while IFS= read -r entry; do
    case "$entry" in
      /*|../*|*/../*|*/..|..|*\\*)
        die "zip contains an unsafe path: $entry"
        ;;
    esac
  done <<<"$listing"
}
