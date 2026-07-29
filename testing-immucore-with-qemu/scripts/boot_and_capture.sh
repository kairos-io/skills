#!/usr/bin/env bash
# Boot an immucore test ISO in QEMU with a custom kernel cmdline and capture
# evidence: full serial console, /run/immucore/immucore.log, journalctl -b,
# and a PNG screendump if the boot hits a red failure screen.
#
# Env knobs (all optional unless stated):
#   IMMUCORE_DIR immucore checkout / dir holding build/ (default: $PWD);
#                only used to locate ISO and LOGDIR defaults
#   ISO          test ISO path (default: newest $IMMUCORE_DIR/build/immucore-test-*.iso)
#   CMDLINE      extra cmdline tokens injected into the first grub entry,
#                e.g. "kairos.ram.create_partitions rd.immucore.debug"
#                (default: "rd.immucore.debug")
#   USERDATA     path to a #cloud-config file; when set, a cidata (NoCloud)
#                ISO is built and attached as a second cdrom so the datasource
#                stage ingests it (use it to create a login user)
#   DISK         existing qcow2 to attach (default: fresh empty 2G)
#   LOGIN_USER / LOGIN_PASS
#                when set, log in on the serial getty and dump immucore +
#                journal logs into LOGDIR
#   CHECK_CMD    extra shell command run as root after login (output fenced
#                into LOGDIR/check.log)
#   LOGDIR       output dir (default: <repo>/build/logs)
#   TIMEOUT      seconds to wait for login prompt / failure screen (default 300)
#   UKI          1 = trusted-boot mode: secureboot OVMF + swtpm TPM2, no grub
#                cmdline injection (auto-detected when the ISO name contains
#                "-uki"). CMDLINE is rejected here — the UKI cmdline is signed
#                at build time, bake tokens with build_test_uki_iso.sh's
#                EXTRA_CMDLINE instead
#   OVMF_CODE / OVMF_VARS
#                firmware override; defaults are the Arch edk2-ovmf paths,
#                secboot CODE in UKI mode. VARS must be a fresh (setup mode)
#                template — the ISO auto-enrolls its keys on first boot via
#                systemd-boot's "secure-boot-enroll if-safe"
#
# Exit codes: 0 boot ok (and login ok if requested), 2 failure screen seen,
# 1 anything else.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# Where ISO/log defaults live: the immucore checkout (or any dir with a
# build/ produced by build_test_iso.sh). Defaults to the current directory.
: "${IMMUCORE_DIR:=$PWD}"

CMDLINE_SET="${CMDLINE+1}"
DISK_SET="${DISK+1}"
: "${CMDLINE:=rd.immucore.debug}"
: "${LOGDIR:=${IMMUCORE_DIR}/build/logs}"
: "${TIMEOUT:=300}"
: "${SERIAL_PORT:=45601}"
: "${MONITOR_PORT:=45602}"

if [[ -z "${ISO:-}" ]]; then
  ISO="$(ls -t "${IMMUCORE_DIR}"/build/immucore-test-*.iso 2>/dev/null | head -1 || true)"
fi
[[ -f "${ISO:-}" ]] || { echo "!!! no test ISO found; run build_test_iso.sh first or set ISO="; exit 1; }

# Trusted-boot mode: explicit UKI=1/0 wins, otherwise sniff the ISO name.
if [[ -z "${UKI:-}" ]]; then
  case "${ISO##*/}" in *-uki*) UKI=1 ;; *) UKI=0 ;; esac
fi

WORK="$(mktemp -d)"
# the || true matters: a failing command in an EXIT trap under set -e
# overwrites the script's exit code
trap 'kill -9 "${qpid:-}" "${tpmpid:-}" 2>/dev/null || true; rm -rf "$WORK"' EXIT
mkdir -p "$LOGDIR"

iso="$WORK/test.iso"
cp "$ISO" "$iso"

if [[ "$UKI" == "1" ]]; then
  # The UKI cmdline is measured and signed — nothing to inject here. Tokens
  # must be baked at build time (build_test_uki_iso.sh EXTRA_CMDLINE).
  if [[ -n "$CMDLINE_SET" ]]; then
    echo "!!! CMDLINE cannot be changed on a UKI ISO (signed cmdline)." >&2
    echo "!!! Rebuild with: EXTRA_CMDLINE=\"${CMDLINE}\" build_test_uki_iso.sh" >&2
    exit 1
  fi
else
  # --- inject cmdline into the first grub entry -----------------------------
  xorriso -indev "$iso" -osirrox on -extract /boot/grub2/grub.cfg "$WORK/grub.cfg" >/dev/null 2>&1
  sed -e 's/set timeout=10/set timeout=1/' \
      -e "0,/rd.cos.disable/{s|rd.cos.disable |${CMDLINE} |}" \
      -e '0,/install-mode /s|install-mode ||' \
      -e '0,/cdroot /s|cdroot ||' \
      "$WORK/grub.cfg" > "$WORK/grub.cfg.new"
  xorriso -boot_image any keep -dev "$iso" -map "$WORK/grub.cfg.new" /boot/grub2/grub.cfg -commit >/dev/null 2>&1
fi

# --- optional cidata ISO from USERDATA ---------------------------------------
CIDATA_ARGS=()
if [[ -n "${USERDATA:-}" ]]; then
  [[ -f "$USERDATA" ]] || { echo "!!! USERDATA file not found: $USERDATA"; exit 1; }
  mkdir "$WORK/cidata"
  cp "$USERDATA" "$WORK/cidata/user-data"
  printf 'instance-id: immucore-qemu-test\n' > "$WORK/cidata/meta-data"
  xorriso -as mkisofs -V cidata -J -R -o "$WORK/cidata.iso" "$WORK/cidata" >/dev/null 2>&1
  CIDATA_ARGS=(-drive "file=$WORK/cidata.iso,format=raw,if=ide,media=cdrom,readonly=on")
fi

# --- disk ---------------------------------------------------------------------
if [[ -z "${DISK:-}" ]]; then
  DISK="$WORK/disk.qcow2"
  qemu-img create -f qcow2 "$DISK" 2G >/dev/null
fi

# --- firmware + trusted-boot extras -------------------------------------------
: "${OVMF_VARS:=/usr/share/OVMF/x64/OVMF_VARS.4m.fd}"
UKI_ARGS=()
if [[ "$UKI" == "1" ]]; then
  # Secureboot-capable firmware needs q35 + SMM, and the flash must be marked
  # secure so the variable store is only writable from SMM.
  : "${OVMF_CODE:=/usr/share/OVMF/x64/OVMF_CODE.secboot.4m.fd}"
  UKI_ARGS+=(-machine q35,smm=on -global driver=cfi.pflash01,property=secure,value=on)

  # TPM 2.0 emulator — the in-RAM trusted-boot workflow encrypts/unlocks
  # partitions against it, and the UKI measures itself into its PCRs.
  # LUKS keyslots are sealed to THIS TPM instance's SRK: reboot scenarios
  # (unlock partitions encrypted on an earlier boot) need the TPM state to
  # survive alongside the disk, so a user-provided DISK pairs with a
  # persistent <disk>.tpmstate dir by default. TPMSTATE overrides; unset
  # DISK keeps both ephemeral.
  command -v swtpm >/dev/null || { echo "!!! swtpm not installed (needed for UKI mode)"; exit 1; }
  if [[ -z "${TPMSTATE:-}" ]]; then
    if [[ -n "$DISK_SET" ]]; then TPMSTATE="${DISK}.tpmstate"; else TPMSTATE="$WORK/tpm"; fi
  fi
  mkdir -p "$TPMSTATE"
  swtpm socket --tpm2 --tpmstate "dir=$TPMSTATE" \
    --ctrl "type=unixio,path=$WORK/tpm.sock" --terminate &
  tpmpid=$!
  UKI_ARGS+=(-chardev "socket,id=chrtpm,path=$WORK/tpm.sock"
             -tpmdev emulator,id=tpm0,chardev=chrtpm
             -device tpm-tis,tpmdev=tpm0)
else
  : "${OVMF_CODE:=/usr/share/OVMF/x64/OVMF_CODE.4m.fd}"
fi

# Fresh copy: the ISO auto-enrolls its secureboot keys into setup-mode vars
# on first boot (systemd-boot "secure-boot-enroll if-safe"), then resets.
vars="$WORK/ovmf_vars.fd"
cp -f "$OVMF_VARS" "$vars"

if [[ "$UKI" == "1" ]]; then
  echo ">>> booting ${ISO##*/} (UKI trusted boot: secureboot OVMF + swtpm; signed cmdline)"
else
  echo ">>> booting ${ISO##*/} with cmdline: ${CMDLINE}"
fi
qemu-system-x86_64 \
  -enable-kvm -cpu host -m 2G -smp 2 \
  "${UKI_ARGS[@]}" \
  -drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}" \
  -drive "if=pflash,format=raw,file=${vars}" \
  -drive "file=${iso},format=raw,if=ide,media=cdrom,readonly=on" \
  "${CIDATA_ARGS[@]}" \
  -drive "file=${DISK},format=qcow2,if=virtio" \
  -boot d -vga std -display none \
  -monitor "telnet:127.0.0.1:${MONITOR_PORT},server,nowait" \
  -serial "telnet:127.0.0.1:${SERIAL_PORT},server,nowait" \
  &
qpid=$!

sleep 2
rc=0
TIMEOUT="$TIMEOUT" LOGIN_USER="${LOGIN_USER:-}" LOGIN_PASS="${LOGIN_PASS:-}" \
CHECK_CMD="${CHECK_CMD:-}" SCREENDUMP="$LOGDIR/failure-screen" \
python3 "$HERE/login_check.py" "$SERIAL_PORT" "$MONITOR_PORT" "$WORK/serial.raw.log" || rc=$?
kill -9 "$qpid" 2>/dev/null || true
wait "$qpid" 2>/dev/null || true

# --- split fenced dumps out of the serial capture -----------------------------
tr -d '\r' < "$WORK/serial.raw.log" | strings > "$LOGDIR/boot-serial.log"
awk '/BEGIN_IMMUCORE_LOG/{f=1;next} /END_IMMUCORE_LOG/{f=0} f' "$LOGDIR/boot-serial.log" > "$LOGDIR/immucore.log"
awk '/BEGIN_JOURNAL/{f=1;next} /END_JOURNAL/{f=0} f'           "$LOGDIR/boot-serial.log" > "$LOGDIR/journalctl.log"
awk '/BEGIN_CHECK/{f=1;next} /END_CHECK/{f=0} f'               "$LOGDIR/boot-serial.log" > "$LOGDIR/check.log"
if [[ -f "$LOGDIR/failure-screen.ppm" ]]; then
  command -v magick >/dev/null && magick "$LOGDIR/failure-screen.ppm" "$LOGDIR/failure-screen.png" && rm -f "$LOGDIR/failure-screen.ppm"
fi
find "$LOGDIR" -maxdepth 1 -empty -delete
echo ">>> exit=$rc; evidence in $LOGDIR:"
ls -la "$LOGDIR"
exit "$rc"
