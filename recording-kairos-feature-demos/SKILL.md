---
name: recording-kairos-feature-demos
description: Use when asked to prepare demo material for a Kairos or AuroraBoot feature - screen recordings or videos of the installer, a boot, a web UI or a CLI flow for a talk, community call or release; side-by-side or sped-up clips; or a slide deck, infographic or PDF that explains a feature to a product team or customers.
---

# Recording Kairos feature demos

## Overview

A demo is evidence: every frame shows the real thing, built from the code that has the feature. The recording tools are in `scripts/` and tested; the work is in choosing what to build and proving the take shows what it claims. Silent clips for a live talk unless asked otherwise; anything that cannot be shown honestly becomes a caveat for the presenter, never a staged shot.

**REQUIRED BACKGROUND:** driving-qemu-vms (QEMU, QMP). Related: testing-kairos-installer-with-hadron, working-with-kairos-extensions.

## The workflow

1. **Inventory what shipped.** For each feature, list its PRs and their state, plus follow-up PRs on the same issue (`gh pr list --search "<issue>"`, the issue's cross-references). Note which are merged, in which release (`gh release list`), and which are open. An open PR the demo needs is merged locally and called out on stage.
2. **Check the whole chain is new enough.** A feature usually has a producer and a consumer (AuroraBoot writes the ISO, the agent/installer inside it acts on it). A released AuroraBoot builds images from released kairos-init: if the consumer is unreleased, build the OS image from kairos master (`make iso` steps 1-3, `scripts/build-iso.sh`) and AuroraBoot from main (`docker build`). Released quay images predate main. The agent, installer, immucore and kairos-init live in the kairos monorepo now: check its releases, not the old per-component repos. In AuroraBoot's **web** builder the templates run the released kairos-init: to get master's consumer there, pick Custom → Dockerfile `FROM <your master-built image>` (kairos-init is skipped when `/etc/kairos-release` exists) or set Output › Advanced › Kairos Init Image.
3. **Preflight the box.** `df -h /` first (an OS image + ISO + VM disk is ~15 GB; ENOSPC looks like a tool bug). `/dev/kvm`, docker, ffmpeg, a Playwright Chromium. Every tool your plan relies on: `which` it before designing around it (no tesseract/zbarimg here: wait on pixels, HTTP and serial instead).
4. **Dry-run with screenshots.** Drive the flow once, screenshot every step, read them. This finds wrong keys, missing commands (busybox `ps` has no `-e`), boot logs under a shell (`clear` first) and static labels that look like end states.
5. **Record real time, edit later.** One scripted take per clip, beats logged with timestamps. Speed up waits in the edit, labelled, never in the recording.
6. **Verify the take.** Contact sheet (`ffmpeg -vf fps=1/8,scale=256:-1,tile=5x5`) plus full-size frames at every claim. Check the artifact itself too (list the ISO, read the API record, the node's journal): the UI can say one thing while the file says another.
7. **Write NOTES.md**: per clip a timestamp table with talking points, the exact versions/SHAs, what is unmerged or unreleased, caveats, and the re-shoot commands. File real bugs the takes exposed (they will).
8. **Clean up** images, VM disks and ISOs you built once the user no longer needs re-shoots.

## Tools (`scripts/`)

| Need | Use |
|---|---|
| Boot a VM with recorder + driver sockets, port-forward the web UI | `vm-up.sh NAME DISK [ISO]` (`DEMO_WEB_PORT`, default 18080: one VM per port) |
| Real-time video of the VM console | `qmprec.py SOCK OUT.mp4 [FPS]`: QMP screendumps piped to ffmpeg, duplicates frames to keep wall-clock time, letterboxes mode changes |
| Drive the VM, wait without sleeps | `vm.py`: `type/key/line`, `wait_stable` (pixel diff, ignores a blinking cursor), `wait_change`, `wait_http` (installer web UI = TUI is up), `wait_serial(log, "reboot: Restarting", "login:")` in order, `wait_size` |
| A whole take with beats | `take.py`: `with Take(name, disk, iso, out) as t:` → `t.vm`, `t.beat()`; clean ACPI shutdown, `OUT.beats.txt`, `OUT.start` |
| Browser take | `browser-helpers.js`: fake cursor, `click/typeInto`, `waitForAny({done, failed})`, dry mode screenshots, `browser.start` for sync |
| Terminal take | `typed-terminal.sh` + asciinema/agg (static binaries from GitHub releases) |
| VM + browser side by side | `side-by-side.sh` (aligns on the `.start` files, placeholder until the browser opens) |
| Speed up dull segments, prepend intros | `speed-segments.sh TAKE OUT "a b speed"... -- intro.mp4` |
| Deck to PDF | `deck-to-pdf.js DECK_ROOT blobs.json OUT.pdf` (Slides artifact files; rasterize with `gs -sDEVICE=png16m` to check pages) |

## Waiting on the right signal

| Moment | Signal |
|---|---|
| Live installer ready | `wait_http()` then `wait_stable(quiet=3)` |
| Install done and rebooted | `wait_serial(log, "reboot: Restarting", "login:")` |
| A TUI page drawn | `wait_stable(quiet=1.5)` after the key |
| Web install/build done | the **status** text that only appears at the end, raced against its failure text; a step list on the page from the start is not an end state |
| Two tracks in sync | wall-clock `.start` files, never "start both at once" |

## Decks and PDFs

Start with the Artifact tool's `quickstart` (`intent: slides`) and the org design system. Get facts from the code through an agent (a cited fact sheet, unverified items marked), not from READMEs; screenshots come from the takes. One slide on what is unreleased. For a PDF, render the slide files with `deck-to-pdf.js` and look at the pages: a code font with ligatures turns `--flag` into `—flag`, so use IBM Plex Mono.

## Common mistakes

| Mistake | Fix |
|---|---|
| Recording a released image, the feature is missing or half there | Step 2: build the consumer from master |
| Slide says "follow-up still to come" for something merged last week | Step 1 includes follow-up PRs |
| Plan built on a tool that isn't installed | Step 3 `which` |
| Waiting on a label that is there from the start | Race end-state text vs failure text |
| `pkill -f pattern` kills your own shell | `pgrep` first, or stop background tasks by id |
| Disk fills mid-build | Step 3; prune build caches, ask before deleting images |
| A take "looks right" but the artifact is wrong | Step 6: check the file, record or journal, not only the screen |
