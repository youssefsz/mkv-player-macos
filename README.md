<p align="center">
  <img src="App/MKVPlayer/Resources/Assets.xcassets/AppIcon.appiconset/icon_128x128.png" width="96" height="96" alt="MKV Player icon">
</p>

<h1 align="center">MKV Player</h1>

<p align="center">
  A focused, native video player for macOS, powered by libmpv.
</p>

<p align="center">
  <a href="https://github.com/youssefsz/mkv-player-macos/actions/workflows/ci.yml"><img src="https://github.com/youssefsz/mkv-player-macos/actions/workflows/ci.yml/badge.svg" alt="CI status"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white" alt="macOS 14 or later">
  <img src="https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white" alt="Swift 6.2">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0--or--later-4c1" alt="GPL-3.0-or-later license"></a>
</p>

MKV Player is built with AppKit and libmpv for people who want a capable local
video player that still feels like a Mac app. It has no account, telemetry,
media-library database, plug-in system, or network-streaming feature.

## Download

Signed and notarized builds are distributed through
[GitHub Releases](https://github.com/youssefsz/mkv-player-macos/releases). If no
binary release is listed yet, follow [Build from source](#build-from-source).

When a release is available:

1. Download `MKV-Player-<version>.dmg`.
2. Open the disk image.
3. Drag **MKV Player** into **Applications**.
4. Open the app and choose a video with **Command-O**.

Release builds include the media engine and support both Apple Silicon and
Intel Macs. Xcode, Homebrew, and separate codec packages are not required.
The automatically generated **Source code** archives on GitHub are intended for
developers; they do not contain a ready-to-run application.

### System requirements

| Requirement | Supported |
| --- | --- |
| macOS | Sonoma 14 or later |
| Mac | Apple Silicon or Intel |
| Distribution | Developer ID signed and Apple notarized |

## Features

- MKV, MP4, M4V, MOV, WebM, AVI, TS, and M2TS containers
- Embedded audio tracks, subtitle tracks, and chapters
- External SRT, ASS/SSA, WebVTT, and other libmpv-supported subtitles
- VideoToolbox hardware decoding with software fallback
- Playback queue with previous and next navigation
- Resume positions and recent files using security-scoped bookmarks
- Native menus, keyboard controls, drag and drop, and fullscreen
- VoiceOver labels, system appearance, and macOS accessibility settings
- Signed automatic updates through Sparkle

Container support does not guarantee every possible codec combination. Format
claims are qualified with the synthetic fixtures in `Tests/Fixtures` and the
manual release checklist.

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| Open video | Command-O |
| Play or pause | Space |
| Seek backward or forward | Left or Right Arrow |
| Enter fullscreen | Control-Command-F |
| Exit fullscreen | Escape |
| Settings | Command-, |
| Close window | Command-W |

Track selection, chapters, playback speed, scaling, and window commands are
also available from the menu bar.

## Privacy and security

Playback stays on the Mac. The app accepts local files only, disables mpv user
configuration and scripts, and builds FFmpeg without network protocols. Its
network entitlement is used only for signed Sparkle update checks.

The application runs in the App Sandbox with read-only access to files selected
by the user. Release artifacts use hardened runtime, Developer ID signing,
Apple notarization, and Sparkle EdDSA signatures.

Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

## Build from source

### Requirements

- macOS 14 or later
- Xcode 26 or later with a Swift 6.2-capable toolchain
- [Homebrew](https://brew.sh)
- Meson, NASM, Ninja, pkg-config, Git, Ruby, and standard Unix build tools

Select Xcode and install its required components:

```sh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch
```

Clone the repository and install the build-only tools:

```sh
git clone https://github.com/youssefsz/mkv-player-macos.git
cd mkv-player-macos

brew install meson nasm ninja pkg-config
gem install xcodeproj --version 1.27.0 --user-install --no-document
```

Build MediaCore for the current Mac, generate the Xcode project, and open it:

```sh
scripts/build-media-core.sh --arch "$(uname -m)"
ruby tools/generate_project.rb
open MKVPlayer.xcodeproj
```

In Xcode, select the shared **MKVPlayer** scheme and **My Mac**, then press
**Command-R**. The first MediaCore build compiles the pinned media stack from
source and can take some time.

To produce a universal MediaCore framework for both Apple Silicon and Intel,
omit the architecture option:

```sh
scripts/build-media-core.sh
ruby tools/generate_project.rb
```

The build downloads only the HTTPS archives and Git commits pinned in
[`scripts/media-core.lock`](scripts/media-core.lock), verifies their hashes, and
writes `Vendor/MediaCore.xcframework`. No Homebrew media library is linked into
the result.

## Tests

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

Playback integration tests use the small, redistributable fixtures committed in
`Tests/Fixtures/Generated`. See [CONTRIBUTING.md](CONTRIBUTING.md) for the full
validation checklist.

## Project layout

| Path | Purpose |
| --- | --- |
| `App/MKVPlayer` | AppKit application and SwiftUI settings |
| `Packages/PlayerCore` | Playback state, persistence, and engine-independent tests |
| `Packages/MPVKit` | libmpv command, event, and OpenGL rendering bridge |
| `scripts` | Reproducible media builds and release verification |
| `Tests/Fixtures` | Synthetic playback fixtures |
| `docs` | Architecture and release documentation |

The threading, rendering, sandbox, and dependency boundaries are documented in
[docs/architecture.md](docs/architecture.md).

## Contributing

Focused bug fixes, accessibility improvements, compatibility results, and
well-scoped features are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) before
opening an issue or pull request.

## License

MKV Player is available under the
[GNU General Public License v3.0 or later](LICENSE). Dependency licenses and
source locations are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
