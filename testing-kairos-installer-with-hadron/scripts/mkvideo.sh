#!/usr/bin/env bash
# Build a video from (png,seconds) pairs by emitting an explicit numbered frame
# sequence (duration*FPS symlinks each), then encoding at constant FPS. This is
# immune to the concat-demuxer image-duration quirks.
# Usage: mkvideo.sh OUT_BASENAME FPS  PNG1 SEC1  PNG2 SEC2 ...
set -euo pipefail
OUT=$1; FPS=$2; shift 2
SEQ=$(mktemp -d)
n=0
while [ $# -gt 0 ]; do
  png=$1; sec=$2; shift 2
  count=$(awk "BEGIN{printf \"%d\", $sec*$FPS}")
  i=0
  while [ $i -lt "$count" ]; do
    ln -s "$png" "$(printf '%s/%06d.png' "$SEQ" "$n")"
    n=$((n+1)); i=$((i+1))
  done
done
ffmpeg -y -loglevel error -framerate "$FPS" -i "$SEQ/%06d.png" \
  -c:v libx264 -pix_fmt yuv420p -movflags +faststart "${OUT}.mp4"
# gif via palette
ffmpeg -y -loglevel error -framerate "$FPS" -i "$SEQ/%06d.png" \
  -vf "fps=12,scale=960:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse" "${OUT}.gif"
rm -rf "$SEQ"
echo "wrote ${OUT}.mp4 (${n} frames @ ${FPS}fps = $(awk "BEGIN{printf \"%.1f\", $n/$FPS}")s) and ${OUT}.gif"
