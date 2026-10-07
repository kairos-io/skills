#!/usr/bin/env bash
# Helpers for a scripted terminal take: commands are typed at a human pace,
# then really executed. Source this from a take script and record it:
#
#   asciinema rec --overwrite --window-size 110x34 -c ./my-take.sh take.cast
#   agg --font-size 22 --theme monokai --idle-time-limit 6 --last-frame-duration 3 take.cast take.gif
#   ffmpeg -y -i take.gif -vf "fps=25,scale=trunc(iw/2)*2:trunc(ih/2)*2,format=yuv420p" -c:v libx264 -crf 18 take.mp4
#
# In my-take.sh:
#   source /path/to/typed-terminal.sh
#   PROMPT_DIR='~/demo'
#   clear
#   say "build the extension"                       # a typed, dimmed comment
#   run "auroraboot sysext acme acme:1.0"           # type it, run it
#   run "show-this --short" "really-run-this 2>&1 | grep -v DBG"   # display != command
#   PAUSE=5 run "cat result.yaml"                   # longer hold after output
#
# asciinema and agg ship static binaries on GitHub releases (asciinema/asciinema,
# asciinema/agg); no pip needed.

GREEN=$'\e[1;32m' BLUE=$'\e[1;34m' DIM=$'\e[2m' RST=$'\e[0m'
: "${PROMPT_USER:=demo}" "${PROMPT_DIR:=~}" "${TYPE_DELAY:=0.045}"

prompt() { printf '%s' "${GREEN}${PROMPT_USER}${RST}:${BLUE}${PROMPT_DIR}${RST}\$ "; }

typeit() {
  local s=$1 i
  for ((i = 0; i < ${#s}; i++)); do
    printf '%s' "${s:i:1}"
    sleep "$TYPE_DELAY"
  done
}

# run "display text" [real command]
run() {
  prompt
  typeit "$1"
  sleep 0.6
  printf '\n'
  eval "${2:-$1}"
  sleep "${PAUSE:-2.5}"
}

say() { prompt; typeit "${DIM}# $1${RST}"; sleep 1.2; printf '\n'; }
