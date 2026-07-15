# Releasing

Only maintainers with the Developer ID, Apple notarization, and Sparkle update
keys can publish a release. A release is acceptable only when it can be rebuilt
from a clean checkout without Homebrew media libraries.

## One-time repository setup

The canonical public repository is
[`youssefsz/mkv-player-macos`](https://github.com/youssefsz/mkv-player-macos).
Its Sparkle feed is published from the `gh-pages` branch at
`https://youssefsz.github.io/mkv-player-macos/appcast.xml`. Treat changes to
either location as a release migration: update the app, verifier, documentation,
and existing clients together.

Configure these GitHub Actions secrets:

| Secret | Purpose |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | Base64-encoded Developer ID Application certificate and private key |
| `DEVELOPER_ID_P12_PASSWORD` | Password protecting the PKCS#12 file |
| `TEMP_KEYCHAIN_PASSWORD` | Random password for the workflow's temporary keychain |
| `APPLE_API_KEY_P8_BASE64` | Base64-encoded App Store Connect API private key used by `notarytool` |
| `APPLE_API_KEY_ID` | App Store Connect API key identifier |
| `APPLE_API_ISSUER_ID` | App Store Connect issuer identifier |
| `APPLE_DEVELOPMENT_TEAM` | Apple Developer team identifier |
| `SPARKLE_ED_PRIVATE_KEY_BASE64` | Base64-encoded Sparkle EdDSA private key file |

Also configure the non-secret repository variable `SPARKLE_PUBLIC_ED_KEY` with
the matching base64 public key. The release workflow passes it to the
`SUPublicEDKey` build setting and fails if it is empty.

Store the matching Sparkle public key in the Xcode build setting consumed by
`SUPublicEDKey`. Keep an offline encrypted backup of the update private key. A
lost key requires a carefully planned key rotation; a leaked key is a security
incident.

Enable GitHub private vulnerability reporting and GitHub Pages from the
`gh-pages` branch. If a repository ruleset protects that branch, add the GitHub
Actions app as an **Always allow** bypass actor; the release workflow performs a
direct, serialized appcast commit and cannot satisfy a required-pull-request
rule. Give the workflow `contents: write` permission only; it does not require
access to issues, packages, deployments, or organization secrets.

Enable GitHub **immutable releases** in the repository settings before creating
the first tag. After publishing, the workflow checks the release object's
`immutable` field and refuses to publish the Sparkle feed unless it is true.
The repository-level setting itself requires an administrator to inspect or
change. This ensures a published tag or asset cannot later be replaced at the
same Sparkle download URL.

Create the repository labels `bug`, `enhancement`, and `documentation` before
the first release so issue forms and generated release notes use consistent
categories.

## Prepare a release

1. Choose a semantic version such as `0.1.0` and update `MARKETING_VERSION` for
   development builds. Tagged releases derive a monotonic Sparkle build number
   as `major × 1,000,000 + minor × 1,000 + patch`; minor and patch components
   must therefore remain below 1,000.
2. Review user-visible changes, known playback limitations, third-party notices,
   and tested format claims.
3. Re-verify every dependency input:

   ```sh
   scripts/verify-media-core-pins.sh
   ```

4. Build MediaCore and run all tests on a clean machine:

   ```sh
   scripts/build-media-core.sh
   gem install xcodeproj --version 1.27.0 --user-install --no-document
   ruby tools/generate_project.rb
   swift test --package-path Packages/PlayerCore
   swift test --package-path Packages/MPVKit
   xcodebuild \
     -project MKVPlayer.xcodeproj \
     -scheme MKVPlayer \
     -destination 'platform=macOS' \
     test
   ```

5. Exercise the release fixture matrix, accessibility settings, repeated seeks,
   sleep/wake, display and audio-device changes, and the 30-minute playback loop
   on Apple Silicon and Intel hardware.
6. Confirm `git status --short` is clean. Create and push a signed tag whose name
   exactly matches the app version:

   ```sh
   git tag -s v0.1.0 -m 'MKV Player 0.1.0'
   git push origin v0.1.0
   ```

## Automated release

The `Release` workflow accepts only `vMAJOR.MINOR.PATCH` tags. It:

1. validates scripts, dependency pins, tag/version agreement, and tests;
2. builds universal MediaCore and archives the app for macOS 14+;
   after MediaCore exists, regenerates the Xcode project so the release archive
   embeds and signs the framework;
3. imports the Developer ID identity into an ephemeral keychain;
4. signs the app with hardened runtime and the sandbox entitlements;
5. notarizes and staples the app, ZIP, and DMG as applicable;
   the DMG uses a pinned layout tool, a compact Finder window, a Retina
   background, fixed app and Applications positions, and a custom volume icon;
6. verifies architecture, bundle identity, minimum system version, code signing,
   notarization, and forbidden local-library paths;
7. creates SHA-256 checksums and Sparkle EdDSA signatures;
8. creates a draft release, uploads every ZIP, DMG, corresponding-source,
   checksum, source-pin, toolchain, license, and notice asset, compares each
   GitHub asset digest with its local SHA-256, and publishes the draft once so
   GitHub locks the tag and assets as an immutable release.

The workflow fails rather than publishing an unsigned or unnotarized artifact.
It derives the public key from the supplied Sparkle private key in an ephemeral
keychain, compares it with the repository variable and archived app, and checks
that the new enclosure has an EdDSA signature before publishing.
Secrets are decoded only into the runner's temporary directory, are never echoed,
and are removed by an `always()` cleanup step.

## Sparkle appcast

The workflow extends the appcast stored with the latest immutable release,
adds the newly signed ZIP enclosure, and then updates the protected `gh-pages`
branch after the GitHub release becomes visible. Treating the last release asset
as canonical also recovers feed history when a prior Pages push failed. Older
supported entries remain available so clients can calculate upgrade paths. The
enclosure URL is the immutable release asset URL and includes its byte length
and EdDSA signature. The containing appcast item records the build version and
minimum system version using Sparkle's canonical top-level elements.

If publication succeeds but the Pages push fails, rerun the same tagged
workflow. It will not replace release artifacts; it downloads the immutable
`appcast.xml` release asset and resumes the Pages publication step.

Before pushing the appcast:

- verify the XML parses and uses HTTPS only;
- verify the EdDSA signature with Sparkle's public key;
- install the previous release and perform an end-to-end update on a clean Mac;
- confirm cancellation and “Check for Updates…” remain functional;
- confirm an archive with a modified byte is rejected.

Do not rewrite an existing release tag or replace an asset at the same URL.
Publish a new patch version if a release artifact is wrong.

## Manual verification and rollback

Download both public artifacts rather than testing the workflow workspace:

```sh
scripts/verify-release.sh \
  --artifact 'MKV-Player-0.1.0.zip' \
  --expected-version 0.1.0 \
  --require-notarization

scripts/verify-release.sh \
  --artifact 'MKV-Player-0.1.0.dmg' \
  --expected-version 0.1.0 \
  --require-notarization
```

Smoke-test the installed app on clean Apple Silicon and Intel Macs without
Homebrew. Verify opening from Finder, drag and drop, recent-file bookmarks,
resume, embedded and external subtitles, multiple audio tracks, fullscreen, and
update checks.

If a release is unsafe, remove its appcast entry first so no additional clients
update. Mark the GitHub release as withdrawn without deleting evidence, publish
a security advisory when appropriate, and ship a higher patch version. Never
reuse the withdrawn version or update-signature tuple.
