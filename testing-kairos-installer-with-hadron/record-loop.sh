#!/usr/bin/env bash
# Periodically screendump a running QEMU guest, producing a numbered PNG
# sequence for a FULL boot-to-end recording (start this right after launching
# QEMU so the recording includes GRUB + boot + console + installer).
#
# Usage:  record-loop.sh QMP_SOCK OUTDIR [INTERVAL_SEC] [QMP_PY]
# Stop:   touch OUTDIR/.stop   (or kill this process)
# Render: ffmpeg -y -framerate 6 -i OUTDIR/%06d.png -c:v libx264 -pix_fmt yuv420p out.mp4
#         (captured every 1s, played at 6fps => ~6x timelapse; tune to taste)
set -euo pipefail
SOCK=$1; OUT=$2; INT=${3:-1}; QMP=${4:-"$(dirname "$0")/qmp.py"}
mkdir -p "$OUT"; rm -f "$OUT/.stop"
n=0
while [ ! -e "$OUT/.stop" ]; do
  f=$(printf '%s/%06d' "$OUT" "$n")
  if python3 "$QMP" "$SOCK" "screendump $f.ppm" >/dev/null 2>&1 && [ -s "$f.ppm" ]; then
    convert "$f.ppm" "$f.png" 2>/dev/null && rm -f "$f.ppm" && n=$((n+1))
  fi
  sleep "$INT"
done
echo "captured $n frames in $OUT"
