# Repository Guidelines

## Project Structure & Module Organization

`App/MKVPlayer/` contains the AppKit application, SwiftUI settings, views, resources, and support adapters. App-level XCTest coverage lives in `App/MKVPlayerTests/`. `Packages/PlayerCore/` owns playback state, persistence, and the engine protocol; keep it independent of AppKit and libmpv. `Packages/MPVKit/` is the sole libmpv/C bridge and rendering layer. Synthetic media fixtures are under `Tests/Fixtures/Generated/`. Build, fixture, and release automation belongs in `scripts/`; architecture and release notes live in `docs/`. Treat `MKVPlayer.xcodeproj` as generated output from `tools/generate_project.rb`.

## Build, Test, and Development Commands

- `scripts/build-media-core.sh --arch "$(uname -m)"` builds the pinned media stack for the current Mac into `Vendor/MediaCore.xcframework`.
- `ruby tools/generate_project.rb` reproducibly regenerates the Xcode project; run it after changing targets, files, or dependencies.
- `open MKVPlayer.xcodeproj` opens the shared `MKVPlayer` scheme for local development.
- `swift test --package-path Packages/PlayerCore` runs engine-independent tests.
- `swift test --package-path Packages/MPVKit` runs command mapping and fallback tests.
- `xcodebuild -project MKVPlayer.xcodeproj -scheme MKVPlayer -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test` runs app and integration tests.
- `bash -n scripts/*.sh` performs a quick shell syntax check; CI also runs ShellCheck and Actionlint.

## Coding Style & Naming Conventions

Use four-space indentation and follow existing Swift formatting; no repository formatter is configured. Name types in `UpperCamelCase`, members in `lowerCamelCase`, and XCTest methods as `testExpectedBehavior`. Prefer immutable value types, explicit actor boundaries, and short functions. Keep UI work on `@MainActor`; never call blocking libmpv APIs from the main actor or render callback. Use native controls, system colors, SF Symbols, and accessibility APIs.

## Testing Guidelines

Tests use XCTest. Add focused unit coverage beside the affected package or in `App/MKVPlayerTests`. Playback changes should exercise synthetic fixtures, rapid seeking, media replacement, pause/resume, and recovery paths. Regenerate fixtures only through `scripts/generate-test-fixtures.sh`, then update checksums. Manually check UI changes with keyboard navigation, VoiceOver, light/dark appearance, Increase Contrast, and Reduce Transparency.

## Commit & Pull Request Guidelines

Recent commits use concise, imperative subjects such as `Tighten hero video spacing`; keep each commit understandable and scoped. Pull requests should lead with the user-visible result, link relevant issues, include tests (or explain why impractical), and add before/after screenshots for visual changes in light and dark modes. Document architecture, dependency, format-support, or release-contract changes. Never commit signing credentials, update keys, local-path logs, unlicensed media, derived data, or `Vendor/MediaCore.xcframework`.
