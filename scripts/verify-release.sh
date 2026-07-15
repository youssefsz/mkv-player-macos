#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_media-core-common.sh
source "$SCRIPT_DIR/_media-core-common.sh"

ARTIFACT=""
EXPECTED_VERSION=""
EXPECTED_BUILD=""
EXPECTED_SPARKLE_PUBLIC_KEY=""
REQUIRE_NOTARIZATION=false

usage() {
  cat <<EOF
Usage: $(basename "$0") --artifact PATH [options]

Verify an MKV Player .app, .zip, or .dmg before publication.

Options:
  --artifact PATH          App bundle, zip archive, or disk image
  --expected-version VER   Require CFBundleShortVersionString to equal VER
  --expected-build NUMBER  Require CFBundleVersion to equal NUMBER
  --expected-sparkle-public-key KEY
                           Require the embedded Sparkle EdDSA public key
  --require-notarization   Require Gatekeeper acceptance and a staple ticket
  -h, --help               Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --artifact)
      [[ $# -ge 2 ]] || die "--artifact requires a path"
      ARTIFACT="$2"
      shift 2
      ;;
    --expected-version)
      [[ $# -ge 2 ]] || die "--expected-version requires a value"
      EXPECTED_VERSION="$2"
      shift 2
      ;;
    --expected-build)
      [[ $# -ge 2 ]] || die "--expected-build requires a value"
      EXPECTED_BUILD="$2"
      shift 2
      ;;
    --expected-sparkle-public-key)
      [[ $# -ge 2 ]] || die "--expected-sparkle-public-key requires a value"
      EXPECTED_SPARKLE_PUBLIC_KEY="$2"
      shift 2
      ;;
    --require-notarization)
      REQUIRE_NOTARIZATION=true
      shift
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

[[ -n "$ARTIFACT" ]] || die "--artifact is required"
[[ -e "$ARTIFACT" ]] || die "artifact does not exist: $ARTIFACT"

for command in codesign ditto file lipo nm otool plutil shasum spctl unzip xcrun; do
  require_command "$command"
done

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/MKVPlayer-verify.XXXXXX")"
mounted_target=""
cleanup() {
  local exit_status=$?

  trap - EXIT
  if [[ -n "$mounted_target" ]]; then
    for _ in 1 2 3; do
      if hdiutil detach "$mounted_target" -quiet; then
        mounted_target=""
        break
      fi
      sleep 1
    done
    if [[ -n "$mounted_target" ]]; then
      hdiutil detach "$mounted_target" -force -quiet || \
        printf 'warning: could not detach disk image mounted at %s\n' "$mounted_target" >&2
    fi
  fi
  rm -rf "$temporary_directory" 2>/dev/null || true
  exit "$exit_status"
}
trap cleanup EXIT

case "$ARTIFACT" in
  *.app)
    APP="$ARTIFACT"
    ;;
  *.zip)
    validate_zip_entries "$ARTIFACT"
    ditto -x -k "$ARTIFACT" "$temporary_directory/unzipped"
    apps=()
    while IFS= read -r -d '' app; do apps+=("$app"); done < <(find "$temporary_directory/unzipped" -type d -name 'MKV Player.app' -print0)
    [[ ${#apps[@]} -eq 1 ]] || die "zip must contain exactly one MKV Player.app"
    APP="${apps[0]}"
    ;;
  *.dmg)
    require_command hdiutil
    mount_point="$temporary_directory/mount"
    mkdir -p "$mount_point"
    hdiutil attach "$ARTIFACT" -nobrowse -readonly -mountpoint "$mount_point" >/dev/null
    mounted_target="$mount_point"
    apps=()
    while IFS= read -r -d '' app; do apps+=("$app"); done < <(find "$mount_point" -maxdepth 2 -type d -name 'MKV Player.app' -print0)
    [[ ${#apps[@]} -eq 1 ]] || die "disk image must contain exactly one MKV Player.app"
    APP="${apps[0]}"
    ;;
  *)
    die "artifact must be an .app, .zip, or .dmg"
    ;;
esac

INFO_PLIST="$APP/Contents/Info.plist"
BINARY="$APP/Contents/MacOS/MKV Player"
MEDIA_BINARY="$APP/Contents/Frameworks/MediaCore.framework/MediaCore"
[[ -f "$INFO_PLIST" ]] || die "app has no Info.plist"
[[ -f "$BINARY" ]] || die "app executable is missing"
[[ -f "$MEDIA_BINARY" ]] || die "release app does not contain MediaCore.framework"

bundle_identifier="$(plutil -extract CFBundleIdentifier raw -o - "$INFO_PLIST")"
version="$(plutil -extract CFBundleShortVersionString raw -o - "$INFO_PLIST")"
build_number="$(plutil -extract CFBundleVersion raw -o - "$INFO_PLIST")"
minimum_system="$(plutil -extract LSMinimumSystemVersion raw -o - "$INFO_PLIST")"
sparkle_public_key="$(plutil -extract SUPublicEDKey raw -o - "$INFO_PLIST")"
sparkle_feed_url="$(plutil -extract SUFeedURL raw -o - "$INFO_PLIST")"
installer_service="$(plutil -extract SUEnableInstallerLauncherService raw -o - "$INFO_PLIST" 2>/dev/null || true)"

[[ "$bundle_identifier" == "io.github.youssefsz.MKVPlayer" ]] || die "unexpected bundle identifier: $bundle_identifier"
[[ "$minimum_system" == "14.0" ]] || die "unexpected minimum macOS version: $minimum_system"
if [[ -n "$EXPECTED_VERSION" && "$version" != "$EXPECTED_VERSION" ]]; then
  die "version mismatch (expected $EXPECTED_VERSION, got $version)"
fi
if [[ -n "$EXPECTED_BUILD" && "$build_number" != "$EXPECTED_BUILD" ]]; then
  die "build number mismatch (expected $EXPECTED_BUILD, got $build_number)"
fi
[[ "$sparkle_public_key" =~ ^[A-Za-z0-9+/]{43}=$ ]] || die "embedded Sparkle public key is missing or malformed"
if [[ -n "$EXPECTED_SPARKLE_PUBLIC_KEY" && "$sparkle_public_key" != "$EXPECTED_SPARKLE_PUBLIC_KEY" ]]; then
  die "embedded Sparkle public key does not match the release key"
fi
[[ "$sparkle_feed_url" == "https://youssefsz.github.io/mkv-player-macos/appcast.xml" ]] || \
  die "unexpected Sparkle feed URL: $sparkle_feed_url"
[[ "$installer_service" == "true" ]] || die "Sparkle installer launcher service is not enabled"
if plutil -extract SUEnableDownloaderService raw -o - "$INFO_PLIST" >/dev/null 2>&1; then
  die "Sparkle downloader service must be disabled when the app has network access"
fi

lipo "$BINARY" -verify_arch arm64 x86_64 || die "app executable is not universal"
lipo "$MEDIA_BINARY" -verify_arch arm64 x86_64 || die "MediaCore is not universal"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign --verify --strict --verbose=2 "$MEDIA_BINARY"
app_signature="$(codesign --display --verbose=4 "$APP" 2>&1)"
grep -q 'flags=.*runtime' <<<"$app_signature" || die "hardened runtime is not enabled"
app_team_identifier="$(sed -n 's/^TeamIdentifier=//p' <<<"$app_signature")"
[[ -n "$app_team_identifier" && "$app_team_identifier" != "not set" ]] || \
  die "app is not signed with a Developer ID team"

media_architectures="$(lipo -archs "$MEDIA_BINARY")"
for architecture in $media_architectures; do
  media_load_commands="$(otool -arch "$architecture" -l "$MEDIA_BINARY")"
  media_minimum_versions="$(
    printf '%s\n' "$media_load_commands" |
      awk '
        $1 == "cmd" {
          in_build_version = ($2 == "LC_BUILD_VERSION")
          next
        }
        in_build_version && $1 == "minos" { print $2 }
      '
  )"
  [[ "$media_minimum_versions" == "14.0" ]] || \
    die "unexpected $architecture MediaCore LC_BUILD_VERSION minos: ${media_minimum_versions:-missing}"

  media_rpaths="$(
    printf '%s\n' "$media_load_commands" |
      awk '
        $1 == "cmd" {
          in_rpath = ($2 == "LC_RPATH")
          next
        }
        in_rpath && $1 == "path" {
          print $2
          in_rpath = 0
        }
      '
  )"
  [[ "$media_rpaths" == "/usr/lib/swift" ]] || \
    die "unexpected $architecture MediaCore LC_RPATH entries: ${media_rpaths:-missing}"

  media_install_name="$(
    otool -arch "$architecture" -D "$MEDIA_BINARY" |
      tail -n +2 |
      head -n 1 |
      sed 's/^[[:space:]]*//'
  )"
  [[ "$media_install_name" == '@rpath/MediaCore.framework/Versions/A/MediaCore' ]] || \
    die "unexpected $architecture MediaCore install name: $media_install_name"
  if otool -arch "$architecture" -L "$MEDIA_BINARY" | tail -n +2 | \
    grep -vE '^[[:space:]]+(@rpath/MediaCore\.framework/|/usr/lib/|/System/Library/Frameworks/)' | \
    grep -q .; then
    die "MediaCore contains a non-system $architecture dynamic dependency"
  fi
done

media_symbols="$(nm -gU "$MEDIA_BINARY")"
for symbol in \
  mpv_create \
  mpv_initialize \
  mpv_command_async \
  mpv_wait_event \
  mpv_render_context_create \
  mpv_render_context_render \
  mpv_render_context_free; do
  grep -Eq "[[:space:]]_${symbol}$" <<<"$media_symbols" || \
    die "MediaCore does not export required symbol: $symbol"
done

entitlements="$temporary_directory/entitlements.plist"
codesign --display --entitlements :- "$APP" >"$entitlements" 2>/dev/null
for entitlement in \
  com.apple.security.app-sandbox \
  com.apple.security.files.bookmarks.app-scope \
  com.apple.security.files.user-selected.read-only \
  com.apple.security.network.client; do
  escaped_entitlement="${entitlement//./\\.}"
  value="$(plutil -extract "$escaped_entitlement" raw -o - "$entitlements" 2>/dev/null || true)"
  [[ "$value" == "true" ]] || die "required entitlement is absent or false: $entitlement"
done

mach_lookup_key='com\.apple\.security\.temporary-exception\.mach-lookup\.global-name'
mach_lookup_values="$(plutil -extract "$mach_lookup_key" json -o - "$entitlements" 2>/dev/null || true)"
for service_suffix in spks spki; do
  grep -Fq "${bundle_identifier}-${service_suffix}" <<<"$mach_lookup_values" || \
    die "Sparkle mach-lookup entitlement is missing: ${bundle_identifier}-${service_suffix}"
done

while IFS= read -r -d '' candidate; do
  if file "$candidate" | grep -q 'Mach-O'; then
    if otool -L "$candidate" | grep -E '/opt/homebrew|/usr/local|/Users/|/private/var/' >/dev/null; then
      die "binary contains a non-system absolute dependency: $candidate"
    fi
    candidate_signature="$(codesign --display --verbose=4 "$candidate" 2>&1)"
    candidate_team_identifier="$(sed -n 's/^TeamIdentifier=//p' <<<"$candidate_signature")"
    [[ "$candidate_team_identifier" == "$app_team_identifier" ]] || \
      die "nested binary is not signed by the app's Developer ID team: $candidate"
    grep -q 'flags=.*runtime' <<<"$candidate_signature" || \
      die "nested binary does not enable hardened runtime: $candidate"
  fi
done < <(find "$APP/Contents" -type f -print0)

if [[ "$REQUIRE_NOTARIZATION" == true ]]; then
  spctl --assess --type execute --verbose=4 "$APP"
  xcrun stapler validate "$APP"
  if [[ "$ARTIFACT" == *.dmg ]]; then
    spctl --assess --type open --context context:primary-signature --verbose=4 "$ARTIFACT"
    xcrun stapler validate "$ARTIFACT"
  fi
fi

log "Verified MKV Player $version ($build_number; $bundle_identifier)"
if [[ -f "$ARTIFACT" ]]; then
  sha256="$(sha256_file "$ARTIFACT")"
  printf 'SHA256 (%s) = %s\n' "$(basename "$ARTIFACT")" "$sha256"
fi
