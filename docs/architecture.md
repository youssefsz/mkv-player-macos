# Architecture

MKV Player separates native presentation, playback state, engine integration,
rendering, and persistence so that no UI decision depends directly on libmpv.

```text
AppKit window, menus, controls, drag and drop
                    |
            @MainActor PlayerSession
                    |
          PlayerEngine async boundary
                    |
                MPVEngine actor
             /                  \
      libmpv client API     MPVVideoSurface
                                 |
                     CGL-backed CAOpenGLLayer
```

## Application layer

`App/MKVPlayer` owns the single standard window, menu validation, file panels,
drag and drop, keyboard shortcuts, accessibility, fullscreen, and the SwiftUI
settings view. It presents immutable player snapshots and sends user intents to
the session. It does not issue decoder commands or parse engine event payloads.

The empty and error states are normal window content, not separate onboarding
flows. The playback overlay uses system controls and materials and hides only
during uninterrupted playback. Appearance and accessibility settings remain
owned by macOS.

## PlayerCore

`Packages/PlayerCore` is a platform-light Swift package containing:

- `PlayerEngine`, the asynchronous playback backend protocol;
- playback phases, snapshots, tracks, chapters, events, and typed errors;
- the `@MainActor` `PlayerSession`, which is the source of truth for UI state;
- time formatting, resume policy, history persistence, and security-scoped file
  access.

Every engine command can fail. `PlayerSession` maps those failures to a
recoverable presentation state and ignores stale events from replaced media.
Tests use a fake engine so state transitions do not require a decoder or GPU.

## MPVKit and threading

`Packages/MPVKit` is the only layer that knows the libmpv ABI. It maps typed
commands and events, owns the client handle, and exposes the video surface.

- The `MPVEngine` actor serializes asynchronous user commands away from the
  main actor. `MPVClient` guards its handle state and reply-ID allocation while
  libmpv's thread-safe API is used from the command, event, and render paths.
- App launch constructs `MPVEngine` on a detached user-initiated executor, so
  dynamic library loading and `mpv_initialize` never block the main actor. The
  finished engine is then injected into the main-actor window controller.
- A dedicated event queue polls `mpv_wait_event` with a bounded timeout and
  translates each result into value types. `mpv_wakeup` interrupts that wait
  when the event pump stops; no event callback mutates AppKit or SwiftUI state.
- Engine events cross the package boundary through one long-lived
  `AsyncStream<PlayerEvent>`. Each load has a unique playback identifier;
  media-scoped events carry that identifier, and the session rejects delayed
  events from files that have already been replaced.
- Position observations are coalesced to at most four UI updates per second.
  Slider dragging remains local and responsive until the final seek is issued.
- Stopping the engine invalidates pending loads and completes only after the
  matching libmpv unload event. This lets the session retain the file's
  security scope until the decoder has really released it. When the engine is
  released, it signals the event pump to stop and finishes its event stream.
  The client and render objects own their respective teardown.

The app forces deterministic engine options before initialization: no user mpv
configuration, scripts, plug-ins, executable downloads, or URL playback;
hardware decoding is `auto-safe`; and local files are the only media input.

## Rendering boundary

`MPVVideoSurface` isolates libmpv's official OpenGL render API behind a native
AppKit view with a CGL-backed `CAOpenGLLayer`. Rendering is scheduled by the
libmpv update callback but performed on the render context's queue. Client
commands never execute from a render callback.

OpenGL is deprecated on macOS, so this is intentionally a replaceable adapter.
`PlayerEngine`, `PlayerSession`, controls, persistence, and menu code must not
refer to CGL or OpenGL types. A future Metal, Vulkan, or custom decoder renderer
can replace `MPVVideoSurface` without changing the application state model.

`Vendor/MediaCore.xcframework` is generated from separately built arm64 and
x86_64 slices and contains a universal dynamic `MediaCore.framework`. It is a
build input, not source control content. MPVKit resolves the framework's libmpv
symbols at runtime, which lets the app shell and tests compile before the binary
is bootstrapped. Public mpv headers are wrapped in one Clang module; non-system
dependency archives are folded into the dynamic framework so release machines
do not depend on Homebrew. Its install name is bundle-relative and Xcode embeds
it in `Contents/Frameworks` for playable builds.

## Files, sandbox, and persistence

The App Sandbox grants user-selected read-only file access and app-scoped
bookmarks. A security-scoped resource remains active for the complete playback
session and is released when media is replaced or the app terminates. External
subtitles receive their own scoped resource.

History is versioned JSON in Application Support, written atomically and capped
to prevent unbounded growth. Positions are saved every five seconds and on
pause, replacement, and termination. A position resumes only when it is more
than 30 seconds from both the beginning and end; completed videos restart.
Recent files fall back to the persisted local path when bookmark resolution
fails. The history entry remains until it is replaced, capped out, or
explicitly cleared.

The app has a network-client entitlement solely for signed Sparkle update
checks. Playback URLs are rejected before they reach libmpv, and FFmpeg is built
without network protocol support as defense in depth.

## Dependency and release boundaries

Source archives are authenticated by SHA-256; libplacebo and its required Git
submodules are authenticated by full commit IDs. The release workflow builds a
universal app, signs every nested executable, enables hardened runtime, submits
the artifacts to Apple's notary service, staples the result, and runs
`scripts/verify-release.sh` before publication.

Sparkle is pinned to 2.9.2. Update metadata and archives are EdDSA-signed with a
key kept outside the repository. Signing identities, notarization credentials,
and update private keys must never appear in build logs or source control.
