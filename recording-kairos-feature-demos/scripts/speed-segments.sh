#!/usr/bin/env bash
# Cut a real-time take into segments, speed up the dull ones, and concatenate
# onto a 1920x1080 25 fps canvas. Optional intro clips (terminal takes) go
# first, unchanged. Pick cut points from the take's .beats.txt.
#
#   speed-segments.sh TAKE.mp4 OUT.mp4 "0 10 1" "10 32 4" "32 101.8 1" ... [-- INTRO.mp4 ...]
#   (each segment: start end speed; speed 1 = real time)
set -euo pipefail
IN=$1 OUT=$2; shift 2
segs=() intros=()
while (($#)); do
  if [[ $1 == -- ]]; then shift; intros=("$@"); break; fi
  segs+=("$1"); shift
done

FIT='scale=1920:1080:force_original_aspect_ratio=decrease:flags=lanczos,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:color=0x0d1117,setsar=1,fps=25,format=yuv420p'
inputs=() filters="" labels="" n=0
for f in "${intros[@]}"; do
  inputs+=(-i "$f"); filters+="[${n}:v]${FIT}[i${n}];"; labels+="[i${n}]"; n=$((n + 1))
done
inputs+=(-i "$IN"); take=$n
i=0
for s in "${segs[@]}"; do
  read -r a b sp <<<"$s"
  filters+="[${take}:v]trim=start=${a}:end=${b},setpts=(PTS-STARTPTS)/${sp},${FIT}[v${i}];"
  labels+="[v${i}]"; i=$((i + 1))
done
filters+="${labels}concat=n=$((n + i)):v=1:a=0[out]"

ffmpeg -v error -y "${inputs[@]}" -filter_complex "$filters" -map '[out]' \
  -c:v libx264 -crf 18 -preset medium -movflags +faststart "$OUT"
printf 'wrote %s (%ss)\n' "$OUT" "$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT")"
