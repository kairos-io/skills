---
name: working-with-kairos-extensions
description: Use when a task touches Kairos system extensions (sysext/confext, `.sysext.raw`), an extensions catalog (`releases.json`, hadron-layers, `extensions.catalogs`), `install.extensions` or `kairos.extensions=`, `auroraboot sysext` / `--extension` / `--extensions-catalog`, the installer's extensions screen, or an extension that fails to resolve, merge or show up on a node.
---

# Working with Kairos system extensions

## Overview

An extension is an erofs image with dm-verity that systemd-sysext merges read-only over `/usr` at boot. A **catalog** is one JSON file mapping names and versions to digest-pinned OCI references. The same catalog format feeds the node, the installer, AuroraBoot (CLI and web) and netboot. Most mistakes come from rules the code enforces silently; the table under Gotchas lists them. **Facts below were verified on kairos master `6e569f2` and AuroraBoot v0.28.0 (2026-10-07); re-check the cited files when the answer matters.**

## Quick reference

**Catalog (`releases.json`)**: parser in kairos `sdk/extensions/catalog.go`.
```json
{"repo": "acme/ext", "layers": [{"name": "acme-agent", "latest": "1.2.0",
  "tags": [{"tag": "1.2.0", "sysext": {
    "amd64": {"oci": "registry.acme.io/sysext/acme-agent@sha256:<64 hex>"},
    "arm64": {"oci": "registry.acme.io/sysext/acme-agent@sha256:<64 hex>"}}}]}]}
```
Required: `name`, `latest` (an unpinned request resolves to it), `tag`, `sysext.<goarch>.oci` with `@sha256:`. `title`/`description` are shown by the AuroraBoot UI only. Version request: exact tag first, else a semver constraint, highest match wins; no fallback to an older version (by design, kairos#4718).

**Build and publish** (copy kairos-io/hadron-layers `.github/workflows/build.yml` and `site/build-data.sh`):
```bash
auroraboot sysext --arch amd64 acme-agent registry.acme.io/acme-agent:1.2.0   # last layer, /usr only
# Trusted Boot flavour: add --private-key db.key --certificate db.pem
oras push --artifact-type application/vnd.kairos.sysext.raw \
  registry.acme.io/sysext/acme-agent:1.2.0-amd64 acme-agent.sysext.raw:application/vnd.kairos.sysext.raw
oras resolve registry.acme.io/sysext/acme-agent:1.2.0-amd64   # digest for releases.json
```

**Consume**

| Where | How |
|---|---|
| Node config | `extensions: {catalogs: [mine, hadron-layers]}` + `install.extensions: [acme-agent@1.2.0, tailscale]` (also `{name, version}`, `oci://…`, `https://…/x.sysext.raw`, absolute path) |
| Running node | `kairos-agent sysext install [--catalog URL]... [--version V] NAME` then `kairos-agent sysext enable --active --now NAME` |
| AuroraBoot CLI | `build-iso`/`build-uki` `--extensions-catalog URL` (repeatable, in order) `--extension name[@ver]` or `--extension file://x.sysext.raw`; config keys `iso.extensions`, `iso.extensions_catalogs` (also raw/cloud disks) |
| AuroraBoot web | `auroraboot web --extensions-catalog URL` / `AURORABOOT_EXTENSIONS_CATALOG`, Settings › Extension catalogs, or the builder's Extensions step |
| Netboot | `kairos.extensions=a@1.0,oci://…@sha256:…` on the cmdline |

Public catalog: `https://kairos-io.github.io/hadron-layers/releases.json`.

## Gotchas

| Symptom / question | Truth (source) |
|---|---|
| Setting a catalog dropped the public extensions | A configured list **replaces** the default. List hadron-layers explicitly after yours. First catalog that publishes the name wins (`sdk/types/extensions/extensions.go`). |
| `architecture "amd64" is not available for layer X` | That version publishes no image for that arch, possibly for **any** arch (`"sysext": {}`). Check the live catalog before suggesting an older pin; e.g. hadron-layers `git` has no image in any version. |
| Want a plain https URL in the catalog | Not supported: `Artifact` has only `oci`, and it must be digest-pinned. Plain URLs work only in `install.extensions` / `--extension`. |
| `kairos.extensions=` ignored | If `install.extensions` is set, the cmdline is not read at all. No merge (`agent/internal/agent/hooks/extensions.go` `DeclaredExtensions`). |
| Installer should offer our private catalog | Not configurable: the installer always uses the default catalog (`installer/internal/wizard/env.go`). Bake images onto the media instead; it lists those, offline. |
| Unticked a media extension in the installer, it still got installed | Every `*.sysext.raw` on the live media is staged and enabled at install, selected or not (`ExtensionsPostInstall` → `StageLiveMediaExtensions`). |
| Extension merged but a file is missing | Nodes merge only `SYSTEMD_SYSEXT_HIERARCHIES` from `kairos-init/pkg/bundled/cloudconfigs/99_sysext.yaml` (master: `/usr/{bin,share,lib,include,src,sbin}`; older releases also `/usr/local/*`: read it at the user's version). `/usr/libexec`, `/opt`, `/etc` never appear. AuroraBoot ≥ v0.28.0 warns at build. |
| Works on GRUB, missing on Trusted Boot | UKI policy is `signed`: unsigned images are silently not merged. Sign with the deployment's db key, or `extensions.ignore_signatures: true` (defeats Trusted Boot; avoid). hadron-layers images are unsigned. |
| Signed image, missing on GRUB | GRUB nodes have no certs loaded; immucore skips signed images there. Publish **two** builds per extension: unsigned (GRUB) and signed (UKI). A catalog maps one image per arch per version, so a mixed fleet needs one catalog per boot type (same names, different digests), each node's `extensions.catalogs` pointing at its own. |
| AuroraBoot build fails on a dead catalog, node doesn't | AuroraBoot fails on any unreadable catalog; the node skips it with a warning. |
| Web UI can't load our catalog | The browser fetches it: the host needs CORS. GitHub Pages works, caches 10 min. |
| hadron-layers extension fails on another flavor | Those images are built for Hadron (kernel modules need the matching kernel). |

## Before answering "is this available"

```bash
curl -s https://kairos-io.github.io/hadron-layers/releases.json | jq -r '.layers[]|.name as $n|.latest as $l|.tags[]|select(.tag==$l)|"\($n)@\($l): \(.sysext|keys|join(","))"'
gh release list -R kairos-io/kairos --limit 3; gh release list -R kairos-io/AuroraBoot --limit 3
```
Catalogs, `install.extensions`, `kairos.extensions=` and the installer picker landed after kairos **v4.3.0**: check that the user's release contains them before recommending one. AuroraBoot carries the extension work from **v0.28.0**.

## Where the code lives

kairos: `sdk/extensions/` (catalog, resolve), `sdk/types/extensions/` (config keys, cmdline), `agent/pkg/extensions/install.go` (node install), `agent/internal/agent/hooks/extensions.go` (install hooks, precedence, live media), `installer/internal/wizard/` (picker), `immucore/internal/constants` (image policies). AuroraBoot: `internal/cmd/sysext.go`, `pkg/extensions/`, `pkg/ops/iso.go` (ISO root + `extensions.yaml`), `ui/src/lib/catalogExtensions.ts`.
