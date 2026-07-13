# Third-party notices

MKV Player is distributed under `GPL-3.0-or-later`. It incorporates or depends
on the projects below. Their copyright notices and license texts remain in their
source distributions and, where required, in release archives.

The exact source URLs, versions, commits, and SHA-256 values used to build the
media stack are recorded in [`scripts/media-core.lock`](scripts/media-core.lock).
Release binaries must be reproducible from those inputs; substituting a system
or Homebrew library is not permitted.

| Component | Pinned version | License | Source |
| --- | --- | --- | --- |
| mpv / libmpv | 0.41.0 | GPL-2.0-or-later | [mpv-player/mpv](https://github.com/mpv-player/mpv) |
| FFmpeg libraries | 8.1.2 | LGPL-2.1-or-later for this configuration; some optional configurations are GPL | [ffmpeg.org](https://ffmpeg.org/) |
| libass | 0.17.4 | ISC | [libass/libass](https://github.com/libass/libass) |
| libplacebo | 7.351.0 | LGPL-2.1-or-later | [haasn/libplacebo](https://github.com/haasn/libplacebo) |
| FreeType | 2.13.3 | FreeType License or GPL-2.0-or-later | [FreeType](https://freetype.org/) |
| FriBidi | 1.0.16 | LGPL-2.1-or-later | [fribidi/fribidi](https://github.com/fribidi/fribidi) |
| HarfBuzz | 10.4.0 | MIT | [harfbuzz/harfbuzz](https://github.com/harfbuzz/harfbuzz) |
| Vulkan-Headers | `cacef3039d277c448c89336290ec3937270b0996` | Apache-2.0 | [KhronosGroup/Vulkan-Headers](https://github.com/KhronosGroup/Vulkan-Headers) |
| Sparkle | 2.9.2 | MIT | [sparkle-project/Sparkle](https://github.com/sparkle-project/Sparkle) |

libplacebo's pinned source also incorporates exact Git submodule revisions for
glad (MIT), Jinja (BSD-3-Clause), MarkupSafe (BSD-3-Clause), and fast_float
(Apache-2.0 with LLVM exception, or MIT), plus the Vulkan-Headers revision shown
above. Vulkan runtime support and demos are disabled, but Vulkan-Headers are
used to compile libplacebo's API stubs. Of libplacebo's pinned third-party
submodules, only Nuklear is excluded from MediaCore.

FFmpeg is built without nonfree components, network protocols, command-line
programs, or external codec libraries. Non-system dependency archives are
statically folded into the dynamic MediaCore framework, and the resulting
framework and application are conveyed under GPL-compatible terms. Enabling
other FFmpeg options can change the license obligations and requires review
before release.

Apple system frameworks and system libraries are linked dynamically and are not
redistributed by this project.

## Corresponding source

Every binary release must include this notice, `scripts/media-core.lock`, the
build scripts, build flags, and a durable link to the exact corresponding source
archives. Maintainers retain those sources for at least as long as the binary
release is offered. The release process must not rely solely on mutable branch
names or package-manager state.

If a notice here conflicts with an upstream license file, the upstream license
file controls. Please report omissions through the normal issue tracker unless
they create a security concern.
