---
name: release-backport
description: >
  Backport a merged fix on main to one or more older release lines by cutting a
  `release/vX.Y.Z` branch off the last tag, cherry-picking with `-x`, pushing, and creating
  a GitHub release tag that does not steal the `Latest` label. Tuned for kairos-io repos
  (kairos, kairos-init, kairos-agent, kairos-sdk, immucore, auroraboot) but generic enough
  for any tag-driven Go release workflow. Use when the user says "backport", "cut a patch
  release", "cherry-pick to release branch", or names a specific patch version to release
  for an older minor line.
---

Cut patch releases on older minor lines from a fix already merged to main. Never mark a
backport as `Latest` — the current-line release owns that label.

## Preconditions

Before doing anything, confirm:

1. Fix is merged into `main` (not just approved). Grab the resulting SHA on main —
   `gh pr view <N> --json mergeCommit` — call it `MERGED_SHA`. Cherry-pick `-x` needs the
   final commit that lives on main, not the PR branch head.
2. Target list of minor lines is explicit. Ask the user if unclear. Do not infer "all old
   releases" — some minors are dead.
3. For each target minor `X.Y`, find the last tag `vX.Y.Z` (`gh release list` or
   `git tag --sort=-v:refname | grep '^vX\.Y\.'`) and the next patch is `vX.Y.(Z+1)`.
4. Sanity-check the fix still applies conceptually before cherry-picking — files may have
   moved, been renamed, or the surrounding logic changed. `git show vX.Y.Z:path/to/file`
   and spot the surrounding context. If the tag is far enough behind that the fix does
   NOT apply as-is (e.g. downstream consumer needs a dep bump instead of a code cherry-pick),
   see "Downstream bump pattern" below.
5. Check the repo has a tag-triggered release workflow at all. Look for
   `.github/workflows/*` with `on: push: tags: v*` (e.g. goreleaser). Confirmed present in
   kairos-io: kairos, kairos-init, kairos-agent, immucore. NOT present in: auroraboot,
   kairos-sdk — for those, pushing a tag will still create the GitHub release but no
   automated artifact build runs (the tag itself is what downstream consumers pin, so
   this is fine, just don't wait for a pipeline that won't fire).

## Per-line procedure

For each target line, run in order:

```
git checkout main
git pull --ff-only
git fetch --tags --prune

git checkout -b release/vX.Y.Z+1 vX.Y.Z
git cherry-pick -x <MERGED_SHA>
# if conflicts: stop, surface diff, ask user before continuing
git push -u origin release/vX.Y.Z+1

gh release create vX.Y.Z+1 \
  --target release/vX.Y.Z+1 \
  --title vX.Y.Z+1 \
  --latest=false \
  --notes "Backport of #<PR>: <one-line summary>."
```

`--latest=false` is mandatory. Kairos-io repos are configured with "Latest by creation date"
in some cases, so a backport tagged AFTER the current-line release will steal `Latest`
unless you pin it. Omitting it makes GitHub promote the backport to `Latest` and demote the
current-line release, which breaks downstream consumers that read `/releases/latest`.

If `--latest=false` was forgotten and the promotion already happened, fix immediately:

```
gh release edit vX.Y.Z+1 --latest=false
gh release edit <current-latest-tag> --latest=true
```

## Component dependency chain (kairos-io)

The recipes below are the *typical* trickle-up shape. Real backports frequently deviate:

- Multiple fixes get batched into a single patch release (cherry-pick several commits
  onto the same `release/vX.Y.Z+1` branch before tagging).
- A fix that lives in main may not apply cleanly to the older branch — you rewrite it by
  hand and the "backport" is a new commit, not a `-x` cherry-pick. Note the origin in the
  commit body.
- Some links in the chain get skipped when nothing between them changed. If init 0.8
  already pinned the agent version you're releasing, you don't need an init bump.
- A backport can start in the *middle* of the chain (e.g. an init-only fix skips sdk and
  agent entirely). Follow the chain from wherever the fix actually lives upward, no
  further.
- Version bumps sometimes include a small follow-up commit (a test fixture, a config
  tweak the new dep needs). That's fine; it stays on the same release branch and gets
  tagged together.
- Occasionally a backport needs a NEW commit that doesn't exist on main at all (e.g. an
  older API-shape adjustment). Author it directly on the release branch — no `-x`
  because there is no source commit to point to.

Use judgement. The chain below is the map, not the itinerary.

A backport in one repo often has to trickle up through every downstream consumer, because
consumers pin an exact version. Chain (arrow = "is consumed by"):

    kairos-sdk  ───►  kairos-agent  ──►  kairos-init  ──►  kairos
                 ╲                    ╱
                  ►  immucore  ──────╯
                 ╲
                  ►  auroraboot   (sibling; not part of the kairos trickle)

Where each consumer pins the previous link:

| Consumer      | Pins           | Location                                          |
|---------------|----------------|---------------------------------------------------|
| kairos-agent  | kairos-sdk     | `go.mod`                                          |
| immucore      | kairos-sdk     | `go.mod`                                          |
| auroraboot    | kairos-sdk, kairos-agent | `go.mod`                                |
| kairos-init   | kairos-sdk     | `go.mod`                                          |
| kairos-init   | kairos-agent   | `Makefile` — `AGENT_VERSION := v...`              |
| kairos-init   | immucore       | `Makefile` — `IMMUCORE_VERSION := v...`           |
| kairos-init   | kcrypt-discovery-challenger | `Makefile` — `KCRYPT_..._VERSION`    |
| kairos-init   | provider-kairos| `Makefile` — `PROVIDER_KAIROS_VERSION`            |
| kairos-init   | edgevpn        | `Makefile` — `EDGEVPN_VERSION`                    |
| kairos        | kairos-init    | `images/Dockerfile` — `ARG KAIROS_INIT=v...`      |

The kairos umbrella repo pins ONLY kairos-init directly. Any backport that has to reach
kairos does so by first landing in kairos-init.

### Trickle-up recipes

Follow the chain from the repo where the fix lives, all the way up to whichever consumer
is affected. Every step is its own `release/vX.Y.Z+1` branch off the previous patch tag.

**Fix in kairos-sdk, affecting an old agent line (e.g. agent 2.27) that ships in kairos:**

1. `kairos-sdk`: cherry-pick fix → tag `vSDK.NEW` (patch on the sdk minor that agent 2.27 uses).
2. `kairos-agent`: `release/v2.27.NEXT` off last `v2.27.*` tag. Commit = `go get github.com/kairos-io/kairos-sdk@vSDK.NEW && go mod tidy`. Tag `v2.27.NEXT`.
3. `kairos-init`: `release/v0.8.NEXT` (or whatever init minor that kairos line uses) off last init patch tag. Commit = bump `AGENT_VERSION := v2.27.NEXT` in Makefile. Tag `v0.8.NEXT`.
4. `kairos`: `release/v4.1.NEXT` off last kairos tag. Commit = bump `ARG KAIROS_INIT=v0.8.NEXT` in `images/Dockerfile`. Tag `v4.1.NEXT`.

**Fix in immucore, affecting an old init line:**

1. `immucore`: cherry-pick fix → tag `vIMMUCORE.NEW`.
2. `kairos-init`: `release/v0.8.NEXT` off last init patch tag. Bump `IMMUCORE_VERSION := vIMMUCORE.NEW` in Makefile. Tag `v0.8.NEXT`.
3. `kairos`: bump `ARG KAIROS_INIT=v0.8.NEXT` in `images/Dockerfile`. Tag `v4.1.NEXT`.

**Fix in kairos-agent, affecting an old init line:**

1. `kairos-agent`: cherry-pick fix → tag `vAGENT.NEW`.
2. `kairos-init`: bump `AGENT_VERSION := vAGENT.NEW` in Makefile. Tag.
3. `kairos`: bump `ARG KAIROS_INIT` in `images/Dockerfile`. Tag.

**Fix in kairos-init itself, affecting an old kairos line:**

1. `kairos-init`: cherry-pick fix. Tag `v0.8.NEXT`.
2. `kairos`: bump `ARG KAIROS_INIT=v0.8.NEXT` in `images/Dockerfile`. Tag.

**Fix in kairos-sdk affecting auroraboot (sibling, not through kairos):**

1. `kairos-sdk`: cherry-pick → tag.
2. `auroraboot`: `release/v0.X.NEXT` off last auroraboot tag. `go get ...@patched && go mod tidy`. Tag.

### Bump-only commits

Version-bump commits are NOT cherry-picks — there is nothing to cherry-pick, the change
is a version string. Write the commit however the repo normally writes them (match the
recent history on that release line's `git log`).

Push and tag as normal (still `--latest=false` unless it IS the current line).

### Figuring out which line pins what

Before starting a chain, resolve the *actual* pinned versions on the target release
branches (they are NOT the versions on main). For every step:

```
gh api repos/kairos-io/<consumer>/contents/<pin-file>?ref=<consumer-release-branch> \
  | jq -r '.content' | base64 -d | grep -E '<pin-line>'
```

Example — what agent version does init 0.8.13 ship?

```
gh api repos/kairos-io/kairos-init/contents/Makefile?ref=release/v0.8.13 \
  | jq -r '.content' | base64 -d | grep AGENT_VERSION
```

This tells you which agent minor to patch. Don't assume — kairos-init 0.8 and 0.14 may
pin different agent minors, and each requires its own trickle path.

### Loop safety

The chain compounds — a single sdk fix might require 4 tags across 4 repos, and each new
tag needs `--latest=false` because none of them are the current line. Batch is fine, but
verify `Latest` in each repo at the end (`gh release list --repo kairos-io/<repo> --limit 3`).

## Conventions this skill assumes

- **Branch naming:** `release/vX.Y.Z` where Z is the patch about to be tagged. Each patch
  gets its own branch. Never reuse a prior line's `release/vX.Y.(Z-1)` branch.
- **Branch base:** always off the previous patch tag `vX.Y.(Z-1)`, never off main. A
  `gh api compare` on kairos-io release branches consistently shows ahead=1..2, behind=0
  vs the previous tag — that's the invariant.
- **Version stamping:** every kairos-io Go repo derives the version from the git tag at
  build time (goreleaser `-ldflags -X ...version={{.Tag}}` in kairos-init/kairos-agent/
  immucore, or `git describe --always --tags --dirty` in kairos-agent's env). Do NOT edit
  a `VERSION` file or bump a hardcoded string — check `.goreleaser.yaml` / `Makefile` /
  workflow env for a `-X ...version=` or `git describe` first.
- **Release trigger:** `push tag v*` fires the release workflow. `gh release create`
  pushes the tag as a side effect, so no manual `git tag && git push --tags` is needed.
- **Cherry-pick trailer:** always use `-x`. It appends `(cherry picked from commit <sha>)`
  which multiple kairos-io repos (immucore, kairos) rely on for traceability. Cherry-pick
  `-x` also preserves the original author + `Signed-off-by` trailer — do not
  `git commit --amend` after the cherry-pick.
- **No force-push on release branches.** If a cherry-pick went wrong, delete the branch
  (and tag/release if already created) and start clean.
- **No PR needed** for the release branch. It's a maintenance branch, not a change under
  review — the code is already reviewed on main via the original PR. Push directly.

## Dry-run first

If multiple lines are being backported (>1), present the plan as a dry-run before executing
and wait for a go signal. One-off backports can proceed directly if the user's request is
unambiguous.

## Report at the end

For each line, print:
- branch name pushed
- cherry-pick commit SHA on that branch
- release URL
- confirm `Latest` still points at the pre-existing current-line release
  (`gh release list --limit 5` to verify)

