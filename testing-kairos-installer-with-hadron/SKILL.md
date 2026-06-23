---
name: testing-kairos-installer-with-hadron
description: Use when you need to test or debug a kairos-installer change on a real Kairos/Hadron ISO booted in a VM — e.g. confirming the interactive installer, the debug-bundle feature, or an install-failure path behaves correctly, or producing a screen recording of an installer run. Keywords: Hadron, AuroraBoot, kairos-agent dispatcher, QEMU, headless TUI, screendump.
---

# Testing a kairos-installer change with Hadron + QEMU

## Overview

Build a Hadron+Kairos ISO that contains your `kairos-installer` build, boot it in
QEMU/KVM, drive the interactive installer with no human at the keyboard (QEMU
`screendump`/`sendkey` over a QMP socket), and record the screen to a video.
The installer runs on the VGA console (`/dev/tty1`), so the QEMU framebuffer is
the source of truth — no terminal-emulator rendering needed.

This is a battle-tested runbook (validated end-to-end). Reusable helpers live in
`scripts/` beside this file: `qmp.py`, `drive.py`, `record-loop.sh`,
`mkvideo.sh`, `fake-agent`, `Dockerfile.installer`.

## Prerequisites

- `docker` (usable), `qemu-system-x86_64` + `/dev/kvm` (be in the `kvm` group),
  `ffmpeg`, ImageMagick `convert`, `python3`.
- Repos: `~/_git/hadron` (build system), `~/_git/kairos-installer` (your change),
  `~/_git/kairos-agent` (to build the dispatcher from master).

## The pipeline (in order)

### 1. Build the installer as a static binary (musl/Hadron-compatible)
```bash
cd ~/_git/kairos-installer
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath \
  -ldflags "-s -w -X github.com/kairos-io/kairos-installer/internal/tui.version=e2e" \
  -o /tmp/build/kairos-installer .
```
`CGO_ENABLED=0` is required — Hadron is musl; a glibc-dynamic binary won't run.

### 2. Build the Hadron+Kairos base image
```bash
cd ~/_git/hadron
make pull-image build-kairos PROGRESS=plain   # produces image hadron-init:latest
```
`pull-image` pulls the prebuilt Hadron base (`ghcr.io/kairos-io/hadron:main`, i.e.
master) — no from-scratch compile.

### 3. Build kairos-agent from master (needed for the dispatcher)
The prebuilt image ships an **older kairos-agent with a built-in installer that
does NOT dispatch** to your binary. Build master and overlay it:
```bash
cd ~/_git/kairos-agent && git worktree add /tmp/ka-main origin/main
cd /tmp/ka-main
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags "-s -w" -o /tmp/build/kairos-agent-main .
```

### 4. Build the derivative image (your installer in the dispatcher override slot)
`kairos-agent interactive-install` resolves the installer in this order:
`$KAIROS_INSTALLER` → `/system/installer/installer` (override slot) →
`/system/installer/kairos-installer` (default). Drop your binary in the override
slot. See `scripts/Dockerfile.installer`:
```bash
cp /tmp/build/kairos-installer /tmp/build/kairos-agent-main scripts/fake-agent /tmp/build/
cd /tmp/build && docker build -q -t hadron-init-installer:test -f scripts/Dockerfile.installer .
```

### 5. Build the ISO with AuroraBoot
```bash
mkdir -p /tmp/build/iso
docker run --rm --privileged -v /var/run/docker.sock:/var/run/docker.sock \
  -v /tmp/build/iso:/output --platform=linux/amd64 \
  quay.io/kairos/auroraboot:v0.21.0-alpha.4 \
  build-iso --output /output/ docker:hadron-init-installer:test
```
(Run long builds/boots via your runtime's background mechanism — a foreground
`cmd &` inside a tool call gets torn down when the call returns.)

### 6. Boot in QEMU (VGA framebuffer + QMP + serial)
```bash
qemu-img create -f qcow2 /tmp/build/disk.img 20G
qemu-system-x86_64 -accel kvm -cpu host -m 3000 -smp 2 \
  -drive if=ide,media=cdrom,file=/tmp/build/iso/kairos-*.iso,readonly=on \
  -drive if=virtio,file=/tmp/build/disk.img,format=qcow2 \
  -boot d -vga std -display none \
  -qmp unix:/tmp/ke.sock,server,nowait \
  -serial file:/tmp/ke-serial.log -name kairos-e2e
```
The live ISO with `install-mode` on its cmdline **drops to a shell on tty1**; the
serial console gets a **root autologin shell** (handy, but `-serial file:` is
output-only). Launch the installer yourself (next step).

### 7. Drive the installer headlessly (see `scripts/drive.py`)
```bash
# NOTE: zsh won't word-split a "python3 scripts/drive.py /tmp/ke.sock" var; call it directly
python3 scripts/drive.py /tmp/ke.sock type 'kairos-agent interactive-install'   # dispatch path
python3 scripts/drive.py /tmp/ke.sock key ret
python3 scripts/drive.py /tmp/ke.sock shot /tmp/build/frames/01.ppm             # then convert to png
python3 scripts/drive.py /tmp/ke.sock key ctrl-d                                # debug bundle hotkey
python3 scripts/drive.py /tmp/ke.sock key 'down down ret'                       # menus
```
`drive.py SOCK type "..."` types text, `key name [name...]` sends keys
(`ret ctrl-d down up esc q spc`), `shot path.ppm` screendumps. To run YOUR binary
directly (bypassing dispatch): `type /system/installer/installer`.

### 8. Record a video — capture frames, then assemble
**For a full boot-to-end recording, start the capture loop right after launching
QEMU** so it includes GRUB + boot + console:
```bash
./scripts/record-loop.sh /tmp/ke.sock /tmp/build/rec 1 &   # screendump every 1s
# ... drive the installer ...
touch /tmp/build/rec/.stop
ffmpeg -y -framerate 6 -i /tmp/build/rec/%06d.png -c:v libx264 -pix_fmt yuv420p full.mp4
```
For a curated clip from specific screenshots, give `scripts/mkvideo.sh`
(png,seconds) pairs: `./scripts/mkvideo.sh out 25  disk.png 3  ready.png 4 ...`
→ `out.mp4` + `out.gif`.

**Do NOT build videos with ffmpeg's concat demuxer + per-image `duration`** — it
does not apply image durations reliably (one frame dominates, others vanish).
`mkvideo.sh` emits an explicit numbered frame sequence (`duration×fps` copies
each) and encodes at constant fps; this is the only method that works here.
**Always extract frames from the finished mp4 and eyeball them.**

### 9. Trigger an install failure (see `scripts/fake-agent`)
To exercise the auto-open-on-failure path and see what the debug bundle captures,
point the installer's agent resolution at a shim that fails `manual-install` but
delegates `logs` to the real agent (so the bundle still gathers journald). The
shim is baked into the image (see `scripts/Dockerfile.installer`) at
`/opt/fake-agent`:
```bash
python3 scripts/drive.py /tmp/ke.sock type 'export KAIROS_AGENT_BIN=/opt/fake-agent ; kairos-agent interactive-install'
python3 scripts/drive.py /tmp/ke.sock key ret
# navigate to start install -> it fails -> debug bundle page auto-opens
```

### 10. Verify HTTP retrieval from the host (optional)
The bundle's HTTP server binds inside the guest on an ephemeral port. Read the
port+token from the screen, then forward it and curl from the host:
```bash
python3 scripts/qmp.py /tmp/ke.sock "hostfwd_add tcp::35791-:<GUEST_PORT>"   # use a FREE host port
curl -s -o /tmp/b.tgz -w '%{http_code}\n' http://127.0.0.1:35791/<TOKEN>/<FILE>
```

## Gotchas (the hard-won lessons)

| Symptom | Cause / Fix |
|---|---|
| Video shows wrong screen / one frame for the whole clip | ffmpeg concat-demuxer image `duration` is unreliable. Use `scripts/mkvideo.sh` (numbered sequence). **Always extract frames from the finished mp4 and eyeball them.** |
| `OSError: AF_UNIX path too long` on the QMP socket | Unix socket paths must be < ~108 chars. Put the socket in `/tmp` (e.g. `/tmp/ke.sock`), not a deep scratch dir. Disk image / ISO paths can be long. |
| Backgrounded QEMU/auroraboot dies when the command returns | A foreground `nohup … &` inside a tool call gets torn down. Use the runtime's real background mechanism (`run_in_background`). |
| Your installer doesn't run; a look-alike does | Prebuilt image's kairos-agent has no dispatcher. Overlay kairos-agent from master (step 3). Confirm your binary by a change only it has (e.g. a help-line string). |
| `GHW_CHROOT` ignored, real host disks show up | `block.New(WithDisableTools(), WithNullAlerter())` (old-style opts) makes ghw skip the `GHW_CHROOT` env default. You can't fake disks for the real binary via env — attach real QEMU devices instead. |
| USB drive not listed as removable (`lsblk RM=0`) | QEMU `usb-storage` defaults `removable=off`. Add `-device usb-storage,…,removable=on` so `/sys/block/sdX/removable==1` (what ghw checks). It needs a partition + filesystem **mounted** to appear in a removable-mount scan. |
| Can't reach the guest's HTTP server from the host | Guest user-net IP is `10.0.2.15`; the host is `10.0.2.2` from the guest. From the host, `hostfwd_add tcp::<freeport>-:<guestport>` (a busy host port makes `hostfwd_add` fail). |
| Need to push a file into the guest | Serve it on the host (`python3 -m http.server`) and `curl http://10.0.2.2:PORT/…` from the guest (curl is present; wget is not on minimal Hadron). |
| `drive.py type` errors `unmapped char` | Add the char to `CHARMAP` in `scripts/drive.py`. Avoid host-side `$(...)`/globs leaking into the typed string — single-quote the argument. |

## Quick reference

- Dispatcher slots: `$KAIROS_INSTALLER` → `/system/installer/installer` → `/system/installer/kairos-installer`.
- Installer runs on `/dev/tty1` when cmdline has `interactive-install`/`install-mode-interactive`; `install-mode` runs the non-interactive `kairos-agent install`.
- Debug bundle path: `/run/kairos/kairos-logs-<ts>.tar.gz`; logs globbed from `/var/log/kairos/*.log`.
- Helpers in `scripts/`: `qmp.py` (one HMP cmd), `drive.py` (type/key/shot), `record-loop.sh` (boot-to-end capture), `mkvideo.sh` (curated clip), `fake-agent` (failure shim), `Dockerfile.installer` (derivative image).
