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

This is a battle-tested runbook (validated end-to-end). Installer-specific
helpers live in `scripts/` beside this file: `fake-agent`, `Dockerfile.installer`.

**REQUIRED BACKGROUND:** the generic QEMU mechanics (launch flags, `drive.py` /
`qmp.py` usage, screen recording, networking/gotchas) live in the
**driving-qemu-vms** skill next to this one; its scripts are at
`../driving-qemu-vms/scripts/`.

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

### 7. Drive the installer headlessly
Use `drive.py` from the driving-qemu-vms skill (`QEMU=../driving-qemu-vms/scripts`):
```bash
# NOTE: zsh won't word-split a "python3 $QEMU/drive.py /tmp/ke.sock" var; call it directly
python3 ../driving-qemu-vms/scripts/drive.py /tmp/ke.sock type 'kairos-agent interactive-install'   # dispatch path
python3 ../driving-qemu-vms/scripts/drive.py /tmp/ke.sock key ret
python3 ../driving-qemu-vms/scripts/drive.py /tmp/ke.sock shot /tmp/build/frames/01.ppm             # then convert to png
python3 ../driving-qemu-vms/scripts/drive.py /tmp/ke.sock key ctrl-d                                # debug bundle hotkey
python3 ../driving-qemu-vms/scripts/drive.py /tmp/ke.sock key 'down down ret'                       # menus
```
To run YOUR binary directly (bypassing dispatch): `type /system/installer/installer`.

### 8. Record a video
See the driving-qemu-vms skill (record-loop.sh + mkvideo.sh, and why the ffmpeg
concat demuxer must NOT be used). Installer-specific note: **start the capture
loop right after launching QEMU** so the recording includes GRUB + boot + console.

### 9. Trigger an install failure (see `scripts/fake-agent`)
To exercise the auto-open-on-failure path and see what the debug bundle captures,
point the installer's agent resolution at a shim that fails `manual-install` but
delegates `logs` to the real agent (so the bundle still gathers journald). The
shim is baked into the image (see `scripts/Dockerfile.installer`) at
`/opt/fake-agent`:
```bash
python3 ../driving-qemu-vms/scripts/drive.py /tmp/ke.sock type 'export KAIROS_AGENT_BIN=/opt/fake-agent ; kairos-agent interactive-install'
python3 ../driving-qemu-vms/scripts/drive.py /tmp/ke.sock key ret
# navigate to start install -> it fails -> debug bundle page auto-opens
```

### 10. Verify HTTP retrieval from the host (optional)
The bundle's HTTP server binds inside the guest on an ephemeral port. Read the
port+token from the screen, then forward it and curl from the host:
```bash
python3 ../driving-qemu-vms/scripts/qmp.py /tmp/ke.sock "hostfwd_add tcp::35791-:<GUEST_PORT>"   # use a FREE host port
curl -s -o /tmp/b.tgz -w '%{http_code}\n' http://127.0.0.1:35791/<TOKEN>/<FILE>
```

## Gotchas (the hard-won lessons)

Generic QEMU gotchas (AF_UNIX path length, backgrounding, video assembly,
hostfwd/networking, USB removable, `drive.py` CHARMAP) are in the
**driving-qemu-vms** skill. Installer-specific ones:

| Symptom | Cause / Fix |
|---|---|
| Your installer doesn't run; a look-alike does | Prebuilt image's kairos-agent has no dispatcher. Overlay kairos-agent from master (step 3). Confirm your binary by a change only it has (e.g. a help-line string). |
| `GHW_CHROOT` ignored, real host disks show up | `block.New(WithDisableTools(), WithNullAlerter())` (old-style opts) makes ghw skip the `GHW_CHROOT` env default. You can't fake disks for the real binary via env — attach real QEMU devices instead. |
| Guest tooling is minimal | curl is present; wget is not on minimal Hadron. |

## Quick reference

- Dispatcher slots: `$KAIROS_INSTALLER` → `/system/installer/installer` → `/system/installer/kairos-installer`.
- Installer runs on `/dev/tty1` when cmdline has `interactive-install`/`install-mode-interactive`; `install-mode` runs the non-interactive `kairos-agent install`.
- Debug bundle path: `/run/kairos/kairos-logs-<ts>.tar.gz`; logs globbed from `/var/log/kairos/*.log`.
- Helpers in `scripts/`: `fake-agent` (failure shim), `Dockerfile.installer` (derivative image). Generic drivers (`qmp.py`, `drive.py`, `record-loop.sh`, `mkvideo.sh`) in `../driving-qemu-vms/scripts/`.
