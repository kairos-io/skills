#!/usr/bin/env bash
# Put a VM track (left) and a browser track (right) on one 1920x1080 canvas,
# aligned on wall-clock time. Each track needs a <file>.start beside it holding
# its start time in epoch milliseconds (take.py and browser-helpers.js write
# them). Before the right track starts its pane shows a placeholder line;
# after it ends, its last frame is held.
#
#   side-by-side.sh LEFT.mp4 LEFT.start RIGHT.webm RIGHT.start OUT.mp4 \
#       "Title" "left label" "right label" ["placeholder text"]
set -euo pipefail
L=$1 LS=$2 R=$3 RS=$4 OUT=$5 TITLE=$6 LLAB=$7 RLAB=$8 WAIT=${9:-}
FONT=${FONT:-/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf}
BOLD=${BOLD:-/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf}

offset=$(awk -v a="$(cat "$RS")" -v b="$(cat "$LS")" 'BEGIN { printf "%.3f", (a - b) / 1000 }')
len=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$L")
echo "right track starts ${offset}s into the left one (left ${len}s)"

esc() { printf '%s' "$1" | sed "s/:/\\\\:/g; s/'/\\\\'/g"; }
label() { printf "drawtext=fontfile=%s:text='%s':x=%s:y=%s:fontsize=%s:fontcolor=%s" "$5" "$(esc "$1")" "$2" "$3" "$4" "$6"; }

wait_label=""
[[ -n "$WAIT" ]] && wait_label=",$(label "$WAIT" 1200 560 26 "$FONT" 0x6e7d91):enable='lt(t,${offset})'"

ffmpeg -v error -y -i "$L" -i "$R" -filter_complex "
  color=c=0x0d1117:s=1920x1080:r=25:d=${len} [bg];
  [0:v] fps=25,scale=1000:800:force_original_aspect_ratio=decrease:flags=lanczos,setsar=1 [left];
  [1:v] fps=25,scale=860:538:flags=lanczos,setsar=1,
        tpad=start_duration=${offset}:start_mode=add:color=0x161b22:stop_mode=clone:stop_duration=3600 [right];
  [bg][left] overlay=30:170:shortest=1 [a];
  [a][right] overlay=1040:301 [b];
  [b] $(label "$TITLE" 30 40 40 "$BOLD" white),
      $(label "$LLAB" 30 125 26 "$FONT" 0x9fb3c8),
      $(label "$RLAB" 1040 256 26 "$FONT" 0x9fb3c8)${wait_label}
" -t "$len" -c:v libx264 -crf 18 -preset medium -pix_fmt yuv420p -movflags +faststart "$OUT"
echo "wrote $OUT"
