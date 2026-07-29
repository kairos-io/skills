#!/usr/bin/env bash

set -euo pipefail

# Trusted-boot variant of build_test_iso.sh.
# Builds a UKI (trusted boot) test ISO from an immucore checkout:
#   1. docker build with Dockerfile.test.uki — hadron-trusted base, full
#      kairos-init (install + init) with -t true, local immucore + agent
#   2. auroraboot build-uki signs the UKI and produces a bootable ISO
#
# Signing keys: KEYS_DIR must hold db.key/db.pem/tpm2-pcr-private.pem plus the
# PK/KEK/db auth files (the exact set `auroraboot genkey` emits). When unset,
# a throwaway INSECURE test key set is generated once under
# ${OUTPUT_DIR}/uki-keys and reused on later runs.
#
# The UKI cmdline is measured and signed — anything you want on it (e.g. the
# kairos.ram.* stanzas) must be baked in NOW via EXTRA_CMDLINE; it cannot be
# edited at boot.

HERE="$(cd "$(dirname "$0")" && pwd)"

: "${IMMUCORE_DIR:=$PWD}"
if ! grep -qs "^module github.com/kairos-io/immucore" "${IMMUCORE_DIR}/go.mod"; then
  echo "!!! ${IMMUCORE_DIR} is not an immucore checkout; set IMMUCORE_DIR=/path/to/immucore" >&2
  exit 1
fi
ROOT="$(cd "${IMMUCORE_DIR}" && pwd)"

VERSION="$(git -C "${ROOT}" describe --always --dirty 2>/dev/null || echo latest)"

: "${IMAGE_TAG:=immucore-test-uki:${VERSION}}"
: "${OUTPUT_DIR:=${ROOT}/build}"
: "${ISO_NAME:=immucore-test-uki-${VERSION}}"
: "${AURORABOOT_IMAGE:=quay.io/kairos/auroraboot:v0.25.0}"
: "${AGENT_REF:=main}"
: "${KEYS_DIR:=${OUTPUT_DIR}/uki-keys}"
# Extra tokens for the signed UKI cmdline, e.g.
#   EXTRA_CMDLINE="kairos.ram kairos.ram.create_partitions"
: "${EXTRA_CMDLINE:=}"

mkdir -p "${OUTPUT_DIR}"

if [ ! -f "${KEYS_DIR}/db.key" ]; then
  echo ">>> No signing keys in ${KEYS_DIR}; generating INSECURE test keys"
  mkdir -p "${KEYS_DIR}"
  docker run --rm \
    -v "${KEYS_DIR}:/keys" \
    "${AURORABOOT_IMAGE}" genkey \
      --expiration-in-days 365 \
      --output /keys \
      "immucore-test"
fi

echo ">>> Building ${IMAGE_TAG} via Dockerfile.test.uki"
docker build \
  -f "${HERE}/Dockerfile.test.uki" \
  --build-arg "AGENT_REF=${AGENT_REF}" \
  -t "${IMAGE_TAG}" \
  "${ROOT}"

echo ">>> Cleaning stale artifacts in ${OUTPUT_DIR}"
rm -f "${OUTPUT_DIR:?}/${ISO_NAME}.iso" "${OUTPUT_DIR:?}/${ISO_NAME}.iso.sha256"

EXTRA_ARGS=()
if [ -n "${EXTRA_CMDLINE}" ]; then
  EXTRA_ARGS+=(--extra-cmdline "${EXTRA_CMDLINE}")
fi

echo ">>> Building UKI ISO via ${AURORABOOT_IMAGE} from ${IMAGE_TAG}"
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "${OUTPUT_DIR}:/out" \
  -v "${KEYS_DIR}:/keys" \
  "${AURORABOOT_IMAGE}" build-uki \
    --output-dir /out \
    --output-type iso \
    --name "${ISO_NAME}" \
    --public-keys /keys \
    --tpm-pcr-private-key /keys/tpm2-pcr-private.pem \
    --sb-key /keys/db.key \
    --sb-cert /keys/db.pem \
    --sdboot-in-source \
    "${EXTRA_ARGS[@]}" \
    "docker:${IMAGE_TAG}"

ls -lh "${OUTPUT_DIR}"/*.iso
echo ">>> Done. Keys (INSECURE, test only) in ${KEYS_DIR}"
