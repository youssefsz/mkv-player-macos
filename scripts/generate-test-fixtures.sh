#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIRECTORY="${1:-$REPOSITORY_ROOT/Tests/Fixtures/Generated}"

command -v ffmpeg >/dev/null 2>&1 || {
  echo "error: ffmpeg is required to generate media fixtures" >&2
  exit 1
}
command -v ffprobe >/dev/null 2>&1 || {
  echo "error: ffprobe is required to verify media fixtures" >&2
  exit 1
}

if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q '[[:space:]]libx264[[:space:]]'; then
  H264_ENCODER=libx264
elif ffmpeg -hide_banner -encoders 2>/dev/null | grep -q '[[:space:]]h264_videotoolbox[[:space:]]'; then
  H264_ENCODER=h264_videotoolbox
else
  echo "error: ffmpeg needs libx264 or h264_videotoolbox" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIRECTORY"
WORK_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/MKVPlayer-fixtures.XXXXXX")"
trap 'rm -rf "$WORK_DIRECTORY"' EXIT

cat >"$WORK_DIRECTORY/subtitles.srt" <<'EOF'
1
00:00:00,200 --> 00:00:00,900
Readable external and embedded subtitles

2
00:00:01,200 --> 00:00:02,100
Unicode: مرحبا · こんにちは · café
EOF

cat >"$WORK_DIRECTORY/subtitles.ass" <<'EOF'
[Script Info]
ScriptType: v4.00+
PlayResX: 1280
PlayResY: 720

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Helvetica,42,&H00FFFFFF,&H000000FF,&H00101010,&H80000000,0,0,0,0,100,100,0,0,1,2,0,2,24,24,28,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.30,0:00:02.10,Default,,0,0,0,,ASS positioning and Unicode: café
EOF

cat >"$WORK_DIRECTORY/chapters.ffmeta" <<'EOF'
;FFMETADATA1
[CHAPTER]
TIMEBASE=1/1000
START=0
END=1200
title=Opening
[CHAPTER]
TIMEBASE=1/1000
START=1200
END=2400
title=Second Act
EOF

COMMON_VIDEO=(
  -f lavfi -i "testsrc2=size=320x180:rate=15"
  -f lavfi -i "sine=frequency=440:sample_rate=48000"
  -t 2.4 -shortest
  -c:v "$H264_ENCODER" -pix_fmt yuv420p
  -c:a aac -b:a 64k
)

ffmpeg -hide_banner -loglevel error -y \
  "${COMMON_VIDEO[@]}" \
  -movflags +faststart \
  "$OUTPUT_DIRECTORY/h264-aac.mp4"

ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "testsrc2=size=320x180:rate=15" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000" \
  -f lavfi -i "sine=frequency=660:sample_rate=48000" \
  -i "$WORK_DIRECTORY/subtitles.srt" \
  -i "$WORK_DIRECTORY/subtitles.ass" \
  -f ffmetadata -i "$WORK_DIRECTORY/chapters.ffmeta" \
  -t 2.4 -shortest \
  -map 0:v:0 -map 1:a:0 -map 2:a:0 -map 3:s:0 -map 4:s:0 \
  -map_chapters 5 \
  -c:v "$H264_ENCODER" -pix_fmt yuv420p \
  -c:a aac -b:a 64k -c:s copy \
  -metadata:s:a:0 language=eng -metadata:s:a:0 title="Main Audio" \
  -metadata:s:a:1 language=fra -metadata:s:a:1 title="Alternate Audio" \
  -metadata:s:s:0 language=eng -metadata:s:s:0 title="English SRT" \
  -metadata:s:s:1 language=eng -metadata:s:s:1 title="Styled ASS" \
  "$OUTPUT_DIRECTORY/tracks-chapters-subtitles.mkv"

ditto "$WORK_DIRECTORY/subtitles.srt" "$OUTPUT_DIRECTORY/external.srt"
ditto "$WORK_DIRECTORY/subtitles.ass" "$OUTPUT_DIRECTORY/external.ass"

dd if="$OUTPUT_DIRECTORY/tracks-chapters-subtitles.mkv" \
  of="$OUTPUT_DIRECTORY/truncated.mkv" bs=512 count=1 2>/dev/null
printf 'not a media container\n' >"$OUTPUT_DIRECTORY/malformed.mkv"

for fixture in "$OUTPUT_DIRECTORY"/*; do
  case "$fixture" in
    *.mp4|*.mkv)
      if [[ "$(basename "$fixture")" != malformed.mkv && "$(basename "$fixture")" != truncated.mkv ]]; then
        ffprobe -v error -show_format -show_streams "$fixture" >/dev/null
      fi
      ;;
  esac
done

(
  cd "$OUTPUT_DIRECTORY"
  rm -f SHA256SUMS.txt
  : > SHA256SUMS.txt
  for fixture in ./*; do
    [[ "$(basename "$fixture")" == SHA256SUMS.txt ]] || \
      shasum -a 256 "$fixture" >> SHA256SUMS.txt
  done
)

echo "Generated short playback fixtures in $OUTPUT_DIRECTORY"
