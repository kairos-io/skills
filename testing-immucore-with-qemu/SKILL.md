---
name: testing-immucore-with-qemu
description: Use when a change to immucore or kairos-agent needs verification in a real boot — building a test ISO from a specific immucore/agent/sdk version or PR, testing kernel cmdline flags (kairos.ram.*, rd.immucore.*), troubleshooting boot failures or red failure screens, checking which yip/cloud-init stages fired, verifying userdata ingestion, or gathering immucore and journald logs from a booted system.
---

# Testing Immucore with QEMU

## Overview

Unit tests can't prove a boot works. This skill boots your local immucore in
QEMU and captures evidence: serial console, `/run/immucore/immucore.log`,
`journalctl -b`, and screendumps of failure screens.

**REQUIRED BACKGROUND:** generic QEMU mechanics (keystroke driving via QMP,
screen recording, guest networking, gotchas) live in the **driving-qemu-vms**
skill next to this one.

## Prerequisites

- A checkout of [kairos-io/immucore](https://github.com/kairos-io/immucore) —
  the version under test. All scripts ship in `scripts/` beside this skill and
  find the checkout via `IMMUCORE_DIR` (default: the current directory, so
  running them from inside the checkout needs no setup).
- `docker`, `qemu-system-x86_64` + `/dev/kvm`, `xorriso`, OVMF firmware,
  ImageMagick (`magick`, for failure-screen PNGs), `python3`.

## Workflow

`SKILL=<path to this skill's directory>`; run from inside the immucore
checkout, or set `IMMUCORE_DIR=/path/to/immucore`.

**1. Build the test ISO** (once per code change, ~5 min):

```bash
$SKILL/scripts/build_test_iso.sh                 # local immucore + kairos-agent@main
AGENT_REF=<branch|tag|sha> $SKILL/scripts/build_test_iso.sh   # pin the agent
```

Picking the versions under test:

- **immucore** — always the local working tree, uncommitted changes included.
  Output: `build/immucore-test-<sha>.iso`; a `-dirty` suffix means the tree
  had uncommitted changes.
- **kairos-agent** — any git ref of kairos-io/kairos-agent via `AGENT_REF`
  (default `main`). For a PR, use its head sha or branch name. Forks need a
  `scripts/Dockerfile.test` edit (the repo URL is hardcoded).
- **kairos-sdk** — no knob. For immucore: `go mod edit -replace` or bump
  `go.mod` locally, then rebuild. For the agent: push a branch of
  kairos-agent with the sdk bump and point `AGENT_REF` at it.

Confirm the booted binaries are the ones you built — stale ISOs are the #1
source of confusing results:

```bash
CHECK_CMD="immucore version; kairos-agent version" ...   # plus login knobs
```

and compare against `git describe` / the agent ref you passed.

**1b. Trusted boot (UKI) test ISO** — for testing immucore's UKI paths
(`rd.immucore.uki`, in-RAM trusted boot, TPM-encrypted partitions):

```bash
$SKILL/scripts/build_test_uki_iso.sh
EXTRA_CMDLINE="kairos.ram kairos.ram.create_partitions" $SKILL/scripts/build_test_uki_iso.sh
```

The pipeline differs from the grub ISO in three places:

1. **Base image changes**: `scripts/Dockerfile.test.uki` starts from the raw
   `ghcr.io/kairos-io/hadron-trusted:main` (systemd-boot flavored hadron) —
   NOT the published kairos-ified `quay.io/kairos/hadron:*` image the grub
   Dockerfile uses. There is no published trusted hadron+kairos image, so the
   full kairos-init pipeline runs in the Dockerfile.
2. **kairos-init needs the trusted flag**: both stages run with `-t true`
   (`kairos-init -s install -t true` then `-s init -t true`). That switches
   the bootloader setup to systemd-boot and skips dracut initramfs generation
   — under trusted boot the whole rootfs becomes the UKI's initramfs, so the
   locally-built immucore is picked up straight from `/usr/bin/immucore`.
3. **auroraboot uses `build-uki` instead of `build-iso`**, and needs signing
   keys: `--public-keys` (PK/KEK/db auth files for firmware auto-enrollment),
   `--sb-key`/`--sb-cert` (db keypair signing the EFI binaries) and
   `--tpm-pcr-private-key` (signs the PCR policy; this is what lets
   `systemd-cryptenroll`-encrypted partitions unlock via TPM at boot).
   `--sdboot-in-source` makes it take systemd-boot from the hadron rootfs
   instead of the bundled one. The script generates a throwaway INSECURE key
   set via `auroraboot genkey` into `build/uki-keys/` on first run; point
   `KEYS_DIR` at real keys to override.

Knobs: `IMMUCORE_DIR`, `AGENT_REF`, `KEYS_DIR`, `EXTRA_CMDLINE`,
`AURORABOOT_IMAGE`, `OUTPUT_DIR`, `ISO_NAME` — same conventions as
`build_test_iso.sh`.

**The UKI cmdline is measured and signed**: `EXTRA_CMDLINE` at build time is
the ONLY way to get tokens onto the cmdline (it extends the default boot
entry via auroraboot `--extend-cmdline`). Editing at boot is not possible
(that is the point of trusted boot), so build one ISO per cmdline scenario.
Tokens you almost always want baked in for testing:

- `rd.immucore.debug console=ttyS0` — debug logs, and immucore/systemd
  output on the serial console the harness captures (`console=` last wins;
  without it immucore's output goes to the VGA console only)
- `kairos.ram kairos.ram.create_partitions` — the in-RAM workflow
- `kairos.pull_datasources` — REQUIRED for `USERDATA` to work on in-RAM UKI
  boots: the `uki_boot_mode` sentinel makes the stock datasource
  cloud-config skip pulling providers (installed UKI systems carry config in
  OEM), and this token re-enables it

`boot_and_capture.sh` boots these ISOs natively: UKI mode is auto-detected
from `-uki` in the ISO name (override with `UKI=1`/`UKI=0`) and switches to
secureboot firmware (`OVMF_CODE.secboot.4m.fd`, q35 + SMM) plus a `swtpm`
TPM 2.0 socket — needed for the TPM PCR encryption/unlock paths. Fresh
setup-mode OVMF vars are used each run; the ISO auto-enrolls its keys on
first boot (systemd-boot `secure-boot-enroll if-safe`) and resets.
`CMDLINE` is rejected in UKI mode (signed cmdline) — the error points you at
`EXTRA_CMDLINE`. Firmware paths default to Arch's edk2-ovmf; override with
`OVMF_CODE`/`OVMF_VARS`. `swtpm` must be installed.

**Reboot scenarios (TPM state must survive)**: LUKS keyslots are sealed to
the specific TPM instance's SRK, so booting a disk encrypted on an earlier
run needs the same swtpm state. When you pass `DISK=`, the harness
automatically persists TPM state next to it (`<disk>.tpmstate`); `TPMSTATE=`
overrides the location. Without `DISK` both disk and TPM are ephemeral.
Second-boot expectations: `ensure-partitions is a no-op` in immucore.log,
partitions unlock via TPM, `/usr/local` data from the previous boot intact.

**2. Boot it with your scenario** (~2 min per boot):

```bash
CMDLINE="kairos.ram.create_partitions rd.immucore.debug" \
USERDATA=$SKILL/scripts/userdata-login.yaml \
LOGIN_USER=kairos LOGIN_PASS=kairos \
CHECK_CMD="kairos-agent state" \
$SKILL/scripts/boot_and_capture.sh
```

`scripts/userdata-login.yaml` is a ready-made cloud-config creating the
kairos/kairos user — use it verbatim or as the base for scenario userdata.

All knobs are documented in the script header. Key ones:

| Knob | Effect |
|------|--------|
| `CMDLINE` | tokens injected into the first grub entry (replaces `rd.cos.disable`, drops `install-mode`/`cdroot`) |
| `USERDATA` | cloud-config file, attached as cidata (NoCloud) cdrom — add a `users:` stage to get login credentials |
| `LOGIN_USER`/`LOGIN_PASS` | log in on serial getty and dump logs from inside |
| `CHECK_CMD` | root shell command, output lands in `check.log` |
| `DISK` | pre-made qcow2 (e.g. foreign GPT for wipe-guard scenarios); default fresh empty 2G |
| `IMMUCORE_DIR` | immucore checkout for ISO/log defaults; default current dir |
| `ISO` | explicit ISO; default newest `$IMMUCORE_DIR/build/immucore-test-*.iso` |
| `LOGDIR` | evidence output dir; default `$IMMUCORE_DIR/build/logs` — set it per scenario to keep runs apart |

Exit codes: `0` boot (+login) ok, `2` red failure screen seen (screendump saved), `1` timeout/error.

**3. Read the evidence** in `LOGDIR` (default `build/logs/`). On exit 2 (failure
screen, no login) only `boot-serial.log` + `failure-screen.png` exist —
`immucore.log`/`journalctl.log`/`check.log` require a successful login:

- `immucore.log` — needs `rd.immucore.debug` in CMDLINE for DBG lines. Grep `sentinel`, `Detected in-RAM`, `Executing stage`.
- `journalctl.log` — full journal. Stage decisions: `grep "Executing stage"` (evaluated) vs `grep "Skip "` + `stage name:` (condition false → skipped). Service starts: `grep ": Started"`.
- `boot-serial.log` — everything, including kernel messages.
- `check.log` — your `CHECK_CMD` output.
- `failure-screen.png` — only on exit 2.

## Common Mistakes

- **Stale ISO**: error messages/flags in the ISO lag your code. Rebuild after every change; check the sha in the ISO name matches `git describe`.
- **No login user**: base image has no default credentials — always pass `USERDATA` with a `users:` stage if you need to get inside.
- **Agent behaves oddly**: published images ship kairos-agent with an older kairos-sdk; the test ISO builds it from `AGENT_REF` (default main) precisely to avoid this.
- **A stage shows in both "Executing" and "Skip" greps**: yip logs `Executing stage` before evaluating its `if:` — the `Skip` line is authoritative.
- **Boot "hangs"**: check `boot-serial.log` first; the failure banner text also appears on serial, and exit 2 + screendump means the boot stopped on purpose.
