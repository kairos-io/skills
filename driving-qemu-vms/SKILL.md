---
name: driving-qemu-vms
description: Use when a task needs to boot an ISO or disk image in QEMU/KVM headlessly and interact with it without a human — sending keystrokes, taking screendumps, scripting a serial-console login, recording the screen to video, or forwarding guest ports. Keywords: QEMU, KVM, QMP, screendump, sendkey, serial console, telnet, OVMF, headless VM, boot testing.
---

# Driving QEMU VMs Headlessly

## Overview

Boot a VM with no display attached and drive it from scripts. Two interaction
channels, pick per target:

| Target | Channel | Tool |
|--------|---------|------|
| VGA console / TUI apps (`/dev/tty1`) | QMP socket: `sendkey` + `screendump` | `scripts/drive.py` |
| Serial getty / shell flows | `-serial telnet:` + expect-style socket script | pattern below |

## Launch recipe

```bash
qemu-system-x86_64 -accel kvm -cpu host -m 2G -smp 2 \
  -drive if=ide,media=cdrom,file=my.iso,readonly=on \
  -drive if=virtio,file=disk.qcow2,format=qcow2 \
  -boot d -vga std -display none \
  -qmp unix:/tmp/vm.sock,server,nowait \
  -serial telnet:127.0.0.1:45601,server,nowait
```

- UEFI: add two pflash drives — readonly `OVMF_CODE` + a writable per-VM copy of `OVMF_VARS`.
- `-serial file:log` is capture-only; use `telnet:` when you must type back.
- Long boots/builds: use your runtime's real background mechanism — a foreground `cmd &` inside a tool call is torn down when the call returns.

## Interacting

**VGA/QMP** (`scripts/drive.py`):

```bash
python3 scripts/drive.py /tmp/vm.sock type 'some-command --flag'
python3 scripts/drive.py /tmp/vm.sock key ret          # also: ctrl-d down up esc q spc
python3 scripts/drive.py /tmp/vm.sock shot frame.ppm   # convert to png with magick
```

`scripts/qmp.py SOCK "hmp command"` runs any single human-monitor command (e.g. `hostfwd_add`).

**Serial expect pattern** — connect a socket to the telnet serial port, pump
`recv` into a buffer + logfile, loop until a needle appears, `sendall` replies:
wait `login:` → send user → wait `Password:` → send pass → send probe commands.
Fence command output with marker lines (`echo BEGIN_"X"` … `echo END_"X"` —
split marker in the command text so the echoed command never matches your
extraction grep) and split the serial log afterwards with awk. Quote guest
commands with `shlex.quote` — nesting quotes inside `sh -c '...'` hangs the
shell. A complete worked example: `tests/qemu/login_check.py` in kairos-io/immucore.

## Recording video

```bash
./scripts/record-loop.sh /tmp/vm.sock /tmp/rec 1 &   # screendump every 1s; stop: touch /tmp/rec/.stop
ffmpeg -y -framerate 6 -i /tmp/rec/%06d.png -c:v libx264 -pix_fmt yuv420p full.mp4
./scripts/mkvideo.sh out 25  shot1.png 3  shot2.png 4   # curated clip -> out.mp4 + out.gif
```

Do NOT use ffmpeg's concat demuxer with per-image `duration` — unreliable.
`mkvideo.sh` emits an explicit numbered frame sequence instead. Always extract
frames from the finished mp4 and eyeball them.

## Gotchas

| Symptom | Cause / Fix |
|---|---|
| `OSError: AF_UNIX path too long` | Socket paths must be < ~108 chars — put sockets in `/tmp`, not deep scratch dirs. |
| Backgrounded QEMU dies when the tool call returns | Use the runtime's background mechanism, not `nohup … &`. |
| Can't reach a guest service from the host | Guest is `10.0.2.15`, host is `10.0.2.2` from the guest. Host side: `qmp.py SOCK "hostfwd_add tcp::<free-host-port>-:<guest-port>"`. |
| Need to push a file into the guest | `python3 -m http.server` on the host, `curl http://10.0.2.2:PORT/...` in the guest. |
| USB stick not seen as removable | `-device usb-storage,...,removable=on`; needs a mounted filesystem to appear in removable scans. |
| `drive.py type` errors `unmapped char` | Add the char to `CHARMAP` in `drive.py`; single-quote the argument so host globs don't leak. |
| Serial output missing early boot | `telnet:...,nowait` drops output until a client connects — connect immediately after launch. |
