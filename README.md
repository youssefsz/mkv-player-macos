# MKV Player

MKV Player is a small, native macOS video player focused on local files. It
uses AppKit for the player window and controls, and libmpv for broad container,
codec, audio-track, chapter, and subtitle support.

The design goal is deliberately modest: a fast player that behaves like a Mac
app. There is no Electron shell, media-library dashboard, account, telemetry,
decorative gradient, or generated-looking visual clutter.

> [!NOTE]
> The project is under active development. The app can be built and its UI and
> state model can be tested without the media engine, but playback requires the
> pinned MediaCore dependency described below.

## Highlights

- Opens MKV, MP4, M4V, MOV, WebM, AVI, TS, and M2TS files.
- Supports embedded audio, subtitle, and chapter tracks exposed by libmpv.
- Loads external SRT, ASS/SSA, WebVTT, and other subtitle formats supported by
  the engine.
- Uses VideoToolbox hardware decoding when it is safe and available, with
  software decoding as a fallback.
- Provides native menus, keyboard control, drag and drop, fullscreen,
  accessibility labels, and system appearance support.
- Remembers recent files and sensible resume positions using sandbox-compatible
  security-scoped bookmarks.
- Keeps playback local. Network access is reserved for Sparkle update checks;
  URL streaming is not a version 1 feature.

Container support does not guarantee every codec combination. The fixtures and
manual compatibility matrix document what a release has actually been tested
with.

## Requirements

- macOS 14 Sonoma or later
- Xcode 26 or later (the app still deploys to macOS 14)
- Swift 6.2-capable toolchain
- For source MediaCore builds: Meson, NASM, Ninja, pkg-config, Git, and standard
  Unix build tools

Both Apple Silicon and Intel Macs are release targets.

## Build

Clone the repository, then build the pinned universal media dependency:

```sh
git clone https://github.com/youssefsz/mkv-player-native.git
cd mkv-player-native
brew install meson nasm ninja pkg-config
gem install xcodeproj --version 1.27.0 --user-install --no-document
scripts/build-media-core.sh
ruby tools/generate_project.rb
open MKVPlayer.xcodeproj
```

The dependency build downloads only the HTTPS sources and Git commits pinned in
[`scripts/media-core.lock`](scripts/media-core.lock), verifies their hashes,
builds separate `arm64` and `x86_64` slices, combines them into one dynamic
framework with its non-system dependencies folded in statically, and writes
`Vendor/MediaCore.xcframework`. The binary is intentionally not committed.

Once maintainers publish a checksum-pinned MediaCore archive, contributors can
use the faster bootstrap path:

```sh
scripts/bootstrap-media-core.sh
ruby tools/generate_project.rb
```

The bootstrap command fails closed if the repository has no published URL and
SHA-256. Project regeneration after either dependency path adds the verified
framework to the app's embed phase. You can audit the source inputs
independently with:

```sh
scripts/verify-media-core-pins.sh
```

Build and test from the command line:

```sh
swift test --package-path Packages/PlayerCore
swift test --package-path Packages/MPVKit
xcodebuild \
  -project MKVPlayer.xcodeproj \
  -scheme MKVPlayer \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| Open video | Command-O |
| Play or pause | Space |
| Seek backward/forward 5 seconds | Left/Right Arrow |
| Enter fullscreen | Control-Command-F |
| Exit fullscreen | Escape |
| Settings | Command-, |
| Close window | Command-W |

Playback, audio, subtitle, chapter, and window commands are also available in
the menu bar so they remain discoverable and accessible.

## Project structure

- `App/MKVPlayer` contains the AppKit application and its small SwiftUI settings
  view.
- `Packages/PlayerCore` contains engine-independent models, session state,
  persistence, and tests.
- `Packages/MPVKit` contains the libmpv command/event bridge and isolated OpenGL
  render surface.
- `scripts` contains reproducible dependency and release verification tooling.
- `docs` contains architecture and maintainer release notes.

See [`docs/architecture.md`](docs/architecture.md) for the threading, rendering,
and sandbox boundaries.

## Contributing and security

Bug reports, focused pull requests, fixture descriptions, accessibility fixes,
and compatibility test results are welcome. Read
[`CONTRIBUTING.md`](CONTRIBUTING.md) before opening a pull request.

Please do not open public issues for vulnerabilities. Follow
[`SECURITY.md`](SECURITY.md) to report them privately.

## License

MKV Player is licensed under the
[GNU General Public License v3.0 or later](LICENSE). Dependency licenses and
source locations are listed in
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
