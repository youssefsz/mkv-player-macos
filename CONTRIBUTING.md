# Contributing to MKV Player

Thank you for helping make a focused, reliable macOS video player. Contributions
should preserve the project's native interaction model, local-file scope,
accessibility, and deterministic media-engine configuration.

## Before opening an issue

- Search existing issues and discussions first.
- For playback bugs, include the macOS version, Mac model, app version, whether
  hardware decoding was active, and the diagnostics copied by the app.
- Describe media with `ffprobe` output when possible. Do not upload copyrighted,
  private, or identifying video without permission.
- Reduce a failing file to a short synthetic sample or provide exact commands
  that create an equivalent fixture.
- Report security problems privately as described in
  [`SECURITY.md`](SECURITY.md).

## Development setup

1. Install Xcode 26 or later and select its command-line tools.
2. Install build-only prerequisites: Meson, NASM, Ninja, pkg-config, and the
   pinned `xcodeproj` Ruby gem.
3. Run `scripts/build-media-core.sh`, or use the checksum-verified bootstrap
   after a binary artifact has been published.
4. Run `ruby tools/generate_project.rb` after MediaCore exists so the generated
   project embeds it.
5. Open `MKVPlayer.xcodeproj` and use the shared `MKVPlayer` scheme.

The dependency installation commands are:

```sh
brew install meson nasm ninja pkg-config
gem install xcodeproj --version 1.27.0 --user-install --no-document
```

Homebrew may supply build tools, but release binaries must not link libraries
from `/opt/homebrew` or `/usr/local`. Media dependencies come only from the
pinned source manifest.

## Making a change

- Keep UI code native and semantic. Prefer AppKit controls, SF Symbols, system
  colors, system typography, menus, and accessibility APIs.
- Do not add decorative gradients, glow, ornamental blur, oversized marketing
  headings, card grids, or web UI.
- Keep `PlayerCore` independent of AppKit and libmpv. New engine behavior belongs
  behind `PlayerEngine` and should be testable with a fake engine.
- Never call blocking libmpv APIs from the main actor or the render callback.
- Do not enable user mpv configuration, scripts, plug-ins, executable downloads,
  or arbitrary network playback.
- Avoid adding dependencies. Explain the need, maintenance cost, binary impact,
  license, and privacy implications in the pull request when one is unavoidable.
- Do not commit `Vendor/MediaCore.xcframework`, derived data, media from unknown
  sources, signing identities, update keys, notarization credentials, or logs
  containing local paths.

## Tests

Run the focused Swift package tests and app tests before opening a pull request:

```sh
swift test --package-path Packages/PlayerCore
swift test --package-path Packages/MPVKit
xcodebuild \
  -project MKVPlayer.xcodeproj \
  -scheme MKVPlayer \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  test
bash -n scripts/*.sh
```

Changes involving playback should also cover the relevant synthetic fixture,
rapid seeks, repeated replacement, pause/resume, and error recovery. UI changes
must be checked with keyboard-only navigation, VoiceOver, Increase Contrast,
Reduce Transparency, light appearance, and dark appearance.

## Pull requests

- Keep each pull request focused and explain the user-visible result first.
- Include tests or explain why automated coverage is impractical.
- Add before/after screenshots for visual changes, including light and dark
  appearances. Do not include real personal media in screenshots.
- Document any format claims with a reproducible fixture and observed decoder.
- Update architecture, release, or third-party documentation when its contract
  changes.
- Make commits understandable; maintainers may squash them when merging.

By contributing, you agree that your contribution is licensed under the
project's `GPL-3.0-or-later` license. No contributor license agreement is
required.
