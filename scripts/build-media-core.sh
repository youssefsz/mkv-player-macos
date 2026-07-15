#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_media-core-common.sh
source "$SCRIPT_DIR/_media-core-common.sh"

ARCHITECTURES=(arm64 x86_64)
OUTPUT="$REPOSITORY_ROOT/Vendor/MediaCore.xcframework"
CACHE_DIR="${MEDIA_CORE_CACHE_DIR:-$HOME/Library/Caches/io.github.youssefsz.MKVPlayer/MediaCore}"
WORK_DIR=""
KEEP_WORK=false
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1735689600}"
INSTALL_PREFIX="/usr/local"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Build a dynamic MediaCore.xcframework from the source pins in media-core.lock.
Non-system media dependencies are linked into its framework binary statically.

Options:
  --arch ARCH           arm64, x86_64, or all (default: all)
  --output PATH         XCFramework output path
  --cache-dir PATH      Verified source download cache
  --work-dir PATH       Build workspace (default: temporary directory)
  --keep-work           Keep a temporary workspace after the build
  -h, --help            Show this help

Prerequisites: Xcode command-line tools, Meson, Ninja, pkg-config, NASM, Git, and
standard Unix build tools. No Homebrew libraries are linked into the result.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)
      [[ $# -ge 2 ]] || die "--arch requires a value"
      case "$2" in
        arm64|x86_64) ARCHITECTURES=("$2") ;;
        all) ARCHITECTURES=(arm64 x86_64) ;;
        *) die "unsupported architecture: $2" ;;
      esac
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || die "--output requires a path"
      OUTPUT="$2"
      shift 2
      ;;
    --cache-dir)
      [[ $# -ge 2 ]] || die "--cache-dir requires a path"
      CACHE_DIR="$2"
      shift 2
      ;;
    --work-dir)
      [[ $# -ge 2 ]] || die "--work-dir requires a path"
      WORK_DIR="$2"
      KEEP_WORK=true
      shift 2
      ;;
    --keep-work)
      KEEP_WORK=true
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

[[ "$OUTPUT" == *.xcframework ]] || die "output must end in .xcframework"
[[ "$SOURCE_DATE_EPOCH" =~ ^[0-9]+$ ]] || die "SOURCE_DATE_EPOCH must be an integer"

for command in awk curl ditto git install_name_tool lipo make meson nasm ninja otool pkg-config rsync shasum strings sysctl tar xcodebuild xcrun; do
  require_command "$command"
done
validate_lock_file

if [[ -z "$WORK_DIR" ]]; then
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/MediaCore-build.XXXXXX")"
else
  mkdir -p "$WORK_DIR"
fi
WORK_DIR="$(cd "$WORK_DIR" && pwd -P)"
HOME_PHYSICAL="$(cd "$HOME" && pwd -P)"
REPOSITORY_ROOT_PHYSICAL="$(cd "$REPOSITORY_ROOT" && pwd -P)"
SYSTEM_TMP_PHYSICAL="$(cd /tmp && pwd -P)"
TMP_ROOT="${TMPDIR:-/tmp}"
TMP_ROOT="${TMP_ROOT%/}"
TMP_ROOT_PHYSICAL="$(cd "$TMP_ROOT" && pwd -P)"

case "$WORK_DIR" in
  *"'"*|*$'\n'*) die "work path contains unsupported characters: $WORK_DIR" ;;
esac
case "$WORK_DIR" in
  /|/Applications|/Library|/System|/Users|/Volumes|/private|/private/var|/var|\
  "$HOME_PHYSICAL"|"$REPOSITORY_ROOT_PHYSICAL"|"$SYSTEM_TMP_PHYSICAL"|"$TMP_ROOT_PHYSICAL")
    die "--work-dir must name a dedicated build directory: $WORK_DIR"
    ;;
esac

cleanup() {
  if [[ "$KEEP_WORK" == true ]]; then
    log "Kept build workspace at $WORK_DIR"
  else
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

export LC_ALL=C
export SOURCE_DATE_EPOCH
export ZERO_AR_DATE=1
unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS CPATH CPLUS_INCLUDE_PATH LIBRARY_PATH \
  SDKROOT MACOSX_DEPLOYMENT_TARGET

"$SCRIPT_DIR/verify-media-core-pins.sh" --cache-dir "$CACHE_DIR"

SOURCE_DIR="$WORK_DIR/sources"
BUILD_DIR="$WORK_DIR/build"
STAGING_DIR="$WORK_DIR/staging"
FRAMEWORK_DIR="$WORK_DIR/frameworks"
rm -rf "$SOURCE_DIR" "$BUILD_DIR" "$STAGING_DIR" "$FRAMEWORK_DIR"
mkdir -p "$SOURCE_DIR" "$BUILD_DIR" "$STAGING_DIR" "$FRAMEWORK_DIR"

for component in "${MEDIA_CORE_COMPONENTS[@]}"; do
  archive_variable="${component}_ARCHIVE"
  directory_variable="${component}_DIRECTORY"
  archive="$CACHE_DIR/downloads/${!archive_variable}"
  destination="$SOURCE_DIR/${!directory_variable}"
  validate_archive_entries "$archive"
  tar -xf "$archive" -C "$SOURCE_DIR"
  [[ -d "$destination" ]] || die "archive did not create expected directory: ${!directory_variable}"
done

LIBPLACEBO_SOURCE="$SOURCE_DIR/libplacebo-$LIBPLACEBO_VERSION"
rm -rf "$LIBPLACEBO_SOURCE"
mkdir -p "$LIBPLACEBO_SOURCE"
rsync -a --delete --exclude='.git' \
  "$CACHE_DIR/libplacebo-$LIBPLACEBO_COMMIT/" \
  "$LIBPLACEBO_SOURCE/"

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
CLANG="$(xcrun --sdk macosx --find clang)"
CLANGXX="$(xcrun --sdk macosx --find clang++)"
AR="$(xcrun --sdk macosx --find ar)"
RANLIB="$(xcrun --sdk macosx --find ranlib)"
STRIP="$(xcrun --sdk macosx --find strip)"
NM="$(xcrun --sdk macosx --find nm)"
PYTHON3="$(xcrun --find python3)"

"$PYTHON3" -c 'import xml.etree.ElementTree as ET; ET.XML("<ok/>")' || \
  die "Xcode Python cannot load its XML parser: $PYTHON3"

write_cross_file() {
  local architecture="$1"
  local output="$2"
  local cpu_family cpu

  case "$architecture" in
    arm64)
      cpu_family="aarch64"
      cpu="arm64"
      ;;
    x86_64)
      cpu_family="x86_64"
      cpu="x86_64"
      ;;
    *) die "unsupported architecture: $architecture" ;;
  esac

  cat >"$output" <<EOF
[binaries]
c = '$CLANG'
cpp = '$CLANGXX'
objc = '$CLANG'
objcpp = '$CLANGXX'
ar = '$AR'
strip = '$STRIP'
pkg-config = 'pkg-config'
python = '$PYTHON3'

[host_machine]
system = 'darwin'
cpu_family = '$cpu_family'
cpu = '$cpu'
endian = 'little'

[properties]
needs_exe_wrapper = true

[built-in options]
prefix = '$INSTALL_PREFIX'
libdir = 'lib'
default_library = 'static'
b_staticpic = true
b_lundef = true
c_args = ['-arch', '$architecture', '-isysroot', '$SDK_PATH', '-mmacosx-version-min=$MEDIA_CORE_MINIMUM_MACOS', '-fvisibility=hidden', '-ffile-prefix-map=$WORK_DIR=.', '-fdebug-prefix-map=$WORK_DIR=.', '-fmacro-prefix-map=$WORK_DIR=.']
cpp_args = ['-arch', '$architecture', '-isysroot', '$SDK_PATH', '-mmacosx-version-min=$MEDIA_CORE_MINIMUM_MACOS', '-fvisibility=hidden', '-ffile-prefix-map=$WORK_DIR=.', '-fdebug-prefix-map=$WORK_DIR=.', '-fmacro-prefix-map=$WORK_DIR=.']
objc_args = ['-arch', '$architecture', '-isysroot', '$SDK_PATH', '-mmacosx-version-min=$MEDIA_CORE_MINIMUM_MACOS', '-fvisibility=hidden', '-ffile-prefix-map=$WORK_DIR=.', '-fdebug-prefix-map=$WORK_DIR=.', '-fmacro-prefix-map=$WORK_DIR=.']
objcpp_args = ['-arch', '$architecture', '-isysroot', '$SDK_PATH', '-mmacosx-version-min=$MEDIA_CORE_MINIMUM_MACOS', '-fvisibility=hidden', '-ffile-prefix-map=$WORK_DIR=.', '-fdebug-prefix-map=$WORK_DIR=.', '-fmacro-prefix-map=$WORK_DIR=.']
c_link_args = ['-arch', '$architecture', '-isysroot', '$SDK_PATH', '-mmacosx-version-min=$MEDIA_CORE_MINIMUM_MACOS', '-lc++', '-liconv']
cpp_link_args = ['-arch', '$architecture', '-isysroot', '$SDK_PATH', '-mmacosx-version-min=$MEDIA_CORE_MINIMUM_MACOS', '-liconv']
objc_link_args = ['-arch', '$architecture', '-isysroot', '$SDK_PATH', '-mmacosx-version-min=$MEDIA_CORE_MINIMUM_MACOS', '-lc++', '-liconv']
objcpp_link_args = ['-arch', '$architecture', '-isysroot', '$SDK_PATH', '-mmacosx-version-min=$MEDIA_CORE_MINIMUM_MACOS', '-liconv']
EOF
}

sanitize_generated_configuration() {
  local header="$1"

  [[ -f "$header" ]] || die "generated configuration header is missing: $header"
  "$PYTHON3" - "$header" "$WORK_DIR" <<'PY'
from pathlib import Path
import sys

header = Path(sys.argv[1])
private_root = sys.argv[2].encode()
contents = header.read_bytes()
sanitized = contents.replace(private_root, b"/MediaCoreBuild")
if sanitized != contents:
    header.write_bytes(sanitized)
PY
}

meson_build() {
  local name="$1"
  local source="$2"
  local architecture="$3"
  local staging_root="$4"
  local cross_file="$5"
  shift 5
  local build="$BUILD_DIR/$architecture/$name"
  local library_type="static"

  if [[ "$name" == "mpv" ]]; then
    library_type="shared"
  fi

  rm -rf "$build"

  if [[ "$name" == "mpv" ]]; then
    meson setup "$build" "$source" \
      --cross-file "$cross_file" \
      --prefix "$INSTALL_PREFIX" \
      --libdir lib \
      --buildtype release \
      --default-library "$library_type" \
      --wrap-mode nodownload \
      --prefer-static \
      "$@"
  else
    meson setup "$build" "$source" \
      --cross-file "$cross_file" \
      --prefix "$INSTALL_PREFIX" \
      --libdir lib \
      --buildtype release \
      --default-library "$library_type" \
      --wrap-mode nodownload \
      "$@"
  fi
  if [[ "$name" == "mpv" ]]; then
    sanitize_generated_configuration "$build/config.h"
  fi
  meson compile -C "$build"
  meson install -C "$build" --destdir "$staging_root"
}

build_ffmpeg() {
  local architecture="$1"
  local staging_root="$2"
  local build="$BUILD_DIR/$architecture/ffmpeg"
  local ffmpeg_arch="$architecture"
  local configure_arguments=(
    "--prefix=$INSTALL_PREFIX"
    "--libdir=$INSTALL_PREFIX/lib"
    "--incdir=$INSTALL_PREFIX/include"
    "--target-os=darwin"
    "--cc=$CLANG"
    "--cxx=$CLANGXX"
    "--ar=$AR"
    "--ranlib=$RANLIB"
    "--strip=$STRIP"
    "--nm=$NM"
    "--host-cc=$CLANG"
    "--host-cflags=-isysroot $SDK_PATH -mmacosx-version-min=$MEDIA_CORE_MINIMUM_MACOS"
    "--host-ld=$CLANG"
    "--host-ldflags=-isysroot $SDK_PATH -mmacosx-version-min=$MEDIA_CORE_MINIMUM_MACOS"
    "--pkg-config=/usr/bin/false"
    "--extra-cflags=-arch $architecture -isysroot $SDK_PATH -mmacosx-version-min=$MEDIA_CORE_MINIMUM_MACOS -fvisibility=hidden -ffile-prefix-map=$WORK_DIR=. -fdebug-prefix-map=$WORK_DIR=. -fmacro-prefix-map=$WORK_DIR=."
    "--extra-cxxflags=-arch $architecture -isysroot $SDK_PATH -mmacosx-version-min=$MEDIA_CORE_MINIMUM_MACOS -fvisibility=hidden -ffile-prefix-map=$WORK_DIR=. -fdebug-prefix-map=$WORK_DIR=. -fmacro-prefix-map=$WORK_DIR=."
    "--extra-ldflags=-arch $architecture -isysroot $SDK_PATH -mmacosx-version-min=$MEDIA_CORE_MINIMUM_MACOS"
    --enable-static
    --disable-shared
    --enable-pic
    --disable-programs
    --disable-doc
    --disable-debug
    --disable-network
    --disable-avdevice
    --disable-autodetect
    --enable-pthreads
    --enable-iconv
    --enable-zlib
    --enable-bzlib
    --disable-lzma
    --enable-audiotoolbox
    --enable-videotoolbox
  )

  [[ "$architecture" != "arm64" ]] || ffmpeg_arch="aarch64"
  configure_arguments+=("--arch=$ffmpeg_arch")
  if [[ "$(uname -m)" != "$architecture" ]]; then
    configure_arguments+=(--enable-cross-compile)
  fi

  rm -rf "$build"
  mkdir -p "$build"
  pushd "$build" >/dev/null
  "$SOURCE_DIR/$FFMPEG_DIRECTORY/configure" "${configure_arguments[@]}"
  sanitize_generated_configuration "$build/config.h"
  make -j"$(sysctl -n hw.logicalcpu)"
  make DESTDIR="$staging_root" install
  popd >/dev/null
}

create_framework() {
  local architecture="$1"
  local prefix="$2"
  local framework="$FRAMEWORK_DIR/$architecture/MediaCore.framework"
  local version_directory="$framework/Versions/A"
  local libraries=()
  local library
  local exported_symbols symbol

  rm -rf "$framework"
  mkdir -p "$version_directory/Headers/mpv" "$version_directory/Modules" "$version_directory/Resources"
  while IFS= read -r -d '' candidate; do
    libraries+=("$candidate")
  done < <(find "$prefix/lib" -type f -name 'libmpv*.dylib' -print0)

  [[ ${#libraries[@]} -eq 1 ]] || die "expected exactly one installed libmpv dylib for $architecture"
  library="${libraries[0]}"
  ditto "$library" "$version_directory/MediaCore"
  install_name_tool -id '@rpath/MediaCore.framework/Versions/A/MediaCore' "$version_directory/MediaCore"

  while IFS= read -r runtime_path; do
    [[ "$runtime_path" == "/usr/lib/swift" ]] || \
      install_name_tool -delete_rpath "$runtime_path" "$version_directory/MediaCore"
  done < <(otool -l "$version_directory/MediaCore" | \
    awk '$1 == "cmd" && $2 == "LC_RPATH" { getline; getline; print $2 }')

  lipo "$version_directory/MediaCore" -verify_arch "$architecture"

  exported_symbols="$("$NM" -gU "$version_directory/MediaCore")"
  for symbol in \
    mpv_create \
    mpv_initialize \
    mpv_terminate_destroy \
    mpv_set_option_string \
    mpv_command_async \
    mpv_client_api_version \
    mpv_error_string \
    mpv_observe_property \
    mpv_get_property_string \
    mpv_wait_event \
    mpv_wakeup \
    mpv_free \
    mpv_render_context_create \
    mpv_render_context_set_update_callback \
    mpv_render_context_render \
    mpv_render_context_report_swap \
    mpv_render_context_free; do
    grep -Eq "[[:space:]]_${symbol}$" <<<"$exported_symbols" || \
      die "MediaCore does not export required symbol $symbol for $architecture"
  done

  if otool -L "$version_directory/MediaCore" | tail -n +2 | \
    grep -vE '^[[:space:]]+(@rpath/MediaCore\.framework/|/usr/lib/|/System/Library/Frameworks/)' | \
    grep -q .; then
    otool -L "$version_directory/MediaCore" >&2
    die "MediaCore has a non-system dynamic dependency for $architecture"
  fi

  if [[ -n "$(strings -a "$version_directory/MediaCore" | grep -F "$WORK_DIR" || true)" ]]; then
    die "MediaCore contains its private build workspace for $architecture"
  fi

  ditto "$prefix/include/mpv" "$version_directory/Headers/mpv"

  cat >"$version_directory/Headers/MediaCore.h" <<'EOF'
#ifndef MEDIA_CORE_H
#define MEDIA_CORE_H

#include <mpv/client.h>
#include <mpv/render.h>
#include <mpv/render_gl.h>
#include <mpv/stream_cb.h>

#endif
EOF

  cat >"$version_directory/Modules/module.modulemap" <<'EOF'
framework module MediaCore {
  umbrella header "MediaCore.h"
  export *

  link framework "ApplicationServices"
  link framework "AudioToolbox"
  link framework "AVFoundation"
  link framework "CoreAudio"
  link framework "CoreFoundation"
  link framework "CoreMedia"
  link framework "CoreText"
  link framework "CoreVideo"
  link framework "IOSurface"
  link framework "OpenGL"
  link framework "Security"
  link framework "VideoToolbox"
  link "bz2"
  link "iconv"
  link "z"
}
EOF

  cat >"$version_directory/Resources/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>MediaCore</string>
  <key>CFBundleIdentifier</key>
  <string>io.github.youssefsz.MediaCore</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>MediaCore</string>
  <key>CFBundlePackageType</key>
  <string>FMWK</string>
  <key>CFBundleShortVersionString</key>
  <string>$MPV_VERSION</string>
  <key>CFBundleSupportedPlatforms</key>
  <array>
    <string>MacOSX</string>
  </array>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MEDIA_CORE_MINIMUM_MACOS</string>
</dict>
</plist>
EOF

  ln -s A "$framework/Versions/Current"
  ln -s Versions/Current/MediaCore "$framework/MediaCore"
  ln -s Versions/Current/Headers "$framework/Headers"
  ln -s Versions/Current/Modules "$framework/Modules"
  ln -s Versions/Current/Resources "$framework/Resources"
}

for architecture in "${ARCHITECTURES[@]}"; do
  log "Building MediaCore for $architecture"
  staging_root="$STAGING_DIR/$architecture"
  prefix="$staging_root$INSTALL_PREFIX"
  cross_file="$BUILD_DIR/$architecture/meson-cross.ini"
  mkdir -p "$prefix" "$(dirname "$cross_file")"
  write_cross_file "$architecture" "$cross_file"

  export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig:$prefix/share/pkgconfig"
  export PKG_CONFIG_PATH=""
  export PKG_CONFIG_SYSROOT_DIR="$staging_root"

  meson_build harfbuzz "$SOURCE_DIR/$HARFBUZZ_DIRECTORY" "$architecture" "$staging_root" "$cross_file" \
    -Dtests=disabled -Ddocs=disabled -Dutilities=disabled -Dbenchmark=disabled \
    -Dglib=disabled -Dgobject=disabled -Dcairo=disabled -Dchafa=disabled \
    -Dicu=disabled -Dgraphite2=disabled -Dfreetype=disabled -Dcoretext=disabled

  meson_build freetype "$SOURCE_DIR/$FREETYPE_DIRECTORY" "$architecture" "$staging_root" "$cross_file" \
    -Dbrotli=disabled -Dbzip2=disabled -Dharfbuzz=disabled -Dpng=disabled -Dzlib=system -Dtests=disabled

  meson_build fribidi "$SOURCE_DIR/$FRIBIDI_DIRECTORY" "$architecture" "$staging_root" "$cross_file" \
    -Ddocs=false -Dbin=false -Dtests=false

  meson_build libass "$SOURCE_DIR/$LIBASS_DIRECTORY" "$architecture" "$staging_root" "$cross_file" \
    -Dtest=disabled -Dcompare=disabled -Dfontconfig=disabled -Dcoretext=enabled \
    -Dlibunibreak=disabled -Drequire-system-font-provider=true

  build_ffmpeg "$architecture" "$staging_root"

  meson_build libplacebo "$LIBPLACEBO_SOURCE" "$architecture" "$staging_root" "$cross_file" \
    -Dvulkan=disabled -Dopengl=enabled -Dgl-proc-addr=disabled \
    -Dglslang=disabled -Dshaderc=disabled -Dlcms=disabled -Ddovi=disabled \
    -Dlibdovi=disabled -Dxxhash=disabled -Dunwind=disabled \
    -Ddemos=false -Dtests=false -Dbench=false -Dfuzz=false

  meson_build mpv "$SOURCE_DIR/$MPV_DIRECTORY" "$architecture" "$staging_root" "$cross_file" \
    -Dgpl=true -Dcplayer=false -Dlibmpv=true -Dbuild-date=false -Dtests=false \
    -Dcplugins=disabled -Djavascript=disabled -Dlua=disabled -Dcdda=disabled \
    -Ddvdnav=disabled -Dlibarchive=disabled -Dlibbluray=disabled \
    -Djpeg=disabled -Djack=disabled -Dopenal=disabled \
    -Drubberband=disabled -Duchardet=disabled -Dvapoursynth=disabled \
    -Dzimg=disabled -Dlcms2=disabled -Dlibavdevice=disabled \
    -Dgl=enabled -Dplain-gl=enabled -Dvulkan=disabled -Dshaderc=disabled \
    -Dcaca=disabled -Dsixel=disabled -Dsdl2-audio=disabled -Dsdl2-video=disabled \
    -Dspirv-cross=disabled -Dcocoa=enabled -Dgl-cocoa=enabled \
    -Dmacos-cocoa-cb=disabled -Dmacos-media-player=disabled \
    -Dmacos-touchbar=disabled -Dswift-build=enabled \
    "-Dswift-flags=-target $architecture-apple-macosx$MEDIA_CORE_MINIMUM_MACOS -debug-prefix-map $WORK_DIR=. -file-prefix-map $WORK_DIR=." \
    -Dcoreaudio=enabled \
    -Davfoundation=disabled -Dvideotoolbox-gl=enabled -Dvideotoolbox-pl=disabled \
    -Diconv=enabled -Dzlib=enabled -Dmanpage-build=disabled -Dhtml-build=disabled

  create_framework "$architecture" "$prefix"
done

if [[ ${#ARCHITECTURES[@]} -eq 2 ]]; then
  release_framework="$FRAMEWORK_DIR/universal/MediaCore.framework"
  rm -rf "$release_framework"
  mkdir -p "$(dirname "$release_framework")"
  ditto "$FRAMEWORK_DIR/arm64/MediaCore.framework" "$release_framework"
  lipo -create \
    "$FRAMEWORK_DIR/arm64/MediaCore.framework/Versions/A/MediaCore" \
    "$FRAMEWORK_DIR/x86_64/MediaCore.framework/Versions/A/MediaCore" \
    -output "$release_framework/Versions/A/MediaCore"
  lipo "$release_framework/Versions/A/MediaCore" -verify_arch arm64 x86_64
else
  release_framework="$FRAMEWORK_DIR/${ARCHITECTURES[0]}/MediaCore.framework"
fi

staged_output="$WORK_DIR/MediaCore.xcframework"
rm -rf "$staged_output"
xcodebuild -create-xcframework -framework "$release_framework" -output "$staged_output"

mkdir -p "$(dirname "$OUTPUT")"
rm -rf "$OUTPUT"
ditto "$staged_output" "$OUTPUT"
log "Created $OUTPUT"
