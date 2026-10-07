#!/usr/bin/env bash
# Start a demo VM in the foreground (run it in the background from the caller).
#
#   vm-up.sh NAME DISK [ISO]
#
# Sockets: /tmp/demo-NAME-rec.sock (recorder), /tmp/demo-NAME-drv.sock (driver)
# Serial:  /tmp/demo-NAME-serial.log
# Web UI:  guest :8080 -> host :${DEMO_WEB_PORT:-18080} (one VM per port)
set -euo pipefail
NAME=$1 DISK=$2 ISO=${3:-}
rm -f /tmp/demo-$NAME-{rec,drv}.sock /tmp/demo-$NAME-serial.log
args=(
  -name "demo-$NAME" -machine q35 -accel kvm -cpu host -m 4096 -smp 4
  -drive "if=virtio,file=$DISK,format=qcow2"
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:${DEMO_WEB_PORT:-18080}-:8080 -device virtio-net-pci,netdev=n0
  -vga std -display none
  -qmp "unix:/tmp/demo-$NAME-rec.sock,server,nowait"
  -qmp "unix:/tmp/demo-$NAME-drv.sock,server,nowait"
  -serial "file:/tmp/demo-$NAME-serial.log"
)
if [[ -n "$ISO" ]]; then
  args+=(-drive "if=ide,media=cdrom,file=$ISO,readonly=on" -boot once=d)
fi
exec qemu-system-x86_64 "${args[@]}"
