# Playback fixtures

The tiny baseline set in `Generated/` is committed so MKV/MP4 integration tests
exercise identical media on developer Macs and in release CI. The complete set
is under 200 KiB and may be regenerated with:

```sh
scripts/generate-test-fixtures.sh
```

The generated set covers H.264/AAC in MP4 and MKV, two selectable audio tracks,
embedded SRT and ASS subtitles, external subtitles, chapters, a deliberately
truncated file, and malformed input. `SHA256SUMS.txt` is verified by CI so a
fixture cannot change unnoticed. Encoding output can differ between FFmpeg
versions or between libx264 and VideoToolbox; commit the regenerated media and
its regenerated checksum file together.

Larger codec samples are deliberately not stored in Git. Release qualification
additionally uses legally redistributable samples for
HEVC Main 10, VP9/Opus, AV1, PGS, DTS, and TrueHD. Those samples are kept out of
the repository because their size and redistribution terms vary. Record sample
hashes, decoder output, hardware-decoding status, dropped frames, and the test
Mac model in the release checklist; never advertise a format or HDR behavior
that was not exercised on both the relevant file and display hardware.

Manual release runs must also cover rapid seeking, repeated replacement, EOF
replay, sleep/wake, display and audio-device changes, fullscreen, a 30-minute
memory/A/V-drift loop, VoiceOver and keyboard-only use, Reduce Motion, Reduce
Transparency, Increase Contrast, light/dark appearance, and clean Intel and
Apple Silicon machines without Homebrew.
