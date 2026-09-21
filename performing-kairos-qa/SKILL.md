---
name: performing-kairos-qa
description: Use when QA is requested on a kairos-io ticket, when picking work from the QA column of GitHub Project 1, when a ticket is moved back into QA for re-testing, or when asked to verify that a merged fix actually works for a user. Covers claiming the request, exercising the change end to end, and reporting PASS, FAIL or BLOCKED with evidence. Not for reviewing a diff, fixing a bug, or chasing red CI.
---

# Performing Kairos QA

QA answers one question: **does this work for somebody who installs Kairos and uses it?**

A green test suite does not answer that question. Neither does a careful reading of the diff. The only thing that answers it is exercising the change the way a user reaches it, and showing what happened.

## The QA column is the source of truth

Work comes from the QA column of [GitHub Project 1](https://github.com/orgs/kairos-io/projects/1/views/1), and from nowhere else. Not the issue list, not your notifications, not a PR that looks ready.

```sh
gh project item-list 1 --owner kairos-io --limit 300 --format json \
  | jq -r '.items[]
      | select(.status == "QA")
      | "\(.content.repository)#\(.content.number) — \(.content.title) (\(.content.url))"'
```

An item sitting in QA means the team wants it tested **now**. That is true even if you tested it before and posted a verdict. A ticket that comes back to QA is a new request, not a duplicate.

Take at most one item per session.

## Claim before you test

Two agents testing the same ticket wastes hours of QEMU time and produces two contradictory verdicts on the same issue.

Read the latest comments first, then post:

```
Picking this up for QA.
```

The hard part is telling a stale claim from a live one. A claim from a previous QA cycle does not block you. Use the timestamps: if the ticket re-entered QA after the last claim and the last verdict, that verdict closed the old cycle and the claim went with it.

**When you cannot tell whether the current cycle is already claimed, skip the ticket.** Duplicate QA is more expensive than a ticket waiting one more cron interval.

## Exercise it, do not just test it

This is where QA runs are usually too shallow. Running `go test ./...` and reporting PASS is not QA; CI already did that, and it is why the ticket reached QA rather than stopping there.

Reach the change the way a user does:

| The change touches | Then QA means |
|---|---|
| ISO or image generation | Build the artifact, boot it in QEMU, confirm the behaviour on the booted system |
| Install, reset, upgrade or recovery | Run that operation end to end on a booted VM and check the machine afterwards |
| The agent CLI or its config schema | Run the command on a booted system with a config that exercises the change |
| immucore or the boot path | Boot it. A boot-path change that was never booted is untested |
| Docs | Follow the instructions exactly as written and see whether they work |

**REQUIRED SUB-SKILLS** for the mechanics, rather than improvising them: `driving-qemu-vms` for headless boots, screendumps and serial consoles; `testing-immucore-with-qemu` for building a test ISO against a specific immucore, agent or SDK version; `testing-kairos-installer-with-hadron` for installer runs on a Hadron image.

Read the repository's `AGENTS.md` before you start. It records the traps that will otherwise cost you the session.

## Stay inside QA

- Do not fix the bug, even when the fix is one line and you can see it.
- Do not open or update a pull request.
- Do not chase red CI or answer reviews.
- Do not widen the test beyond what validates this ticket.

Problems you find along the way get reported, not fixed. A bug you notice while testing something else is worth a sentence in your report, and that is all.

## Report

Post the verdict as a new comment. Never edit an old verdict to carry a new one: the QA history on the ticket is the record of how many cycles it took.

```markdown
### QA Result: PASS | FAIL | BLOCKED

| Check        | Result                           |
| ------------ | -------------------------------- |
| Environment  | `<version, image, arch>`         |
| Reproduction | `<what was actually run>`        |
| Expected     | `<expected behaviour>`           |
| Actual       | `<observed behaviour>`           |
| Proofs       | `<what is attached>`             |

**Summary:** `<one or two sentences>`
```

**Attach proof.** A verdict with no evidence cannot be acted on, and cannot be checked later. Logs, a serial console capture, a screendump, a QEMU recording, the failing output. Keep it short: the relevant lines, not the whole journal.

Then label the issue:

| Verdict | Label | Board |
|---|---|---|
| PASS | `QA: pass` | Move the card to `QA OK` |
| FAIL | `QA: fail` | Leave it in QA for the team |
| BLOCKED | no label | Leave it in QA, say what is missing |

BLOCKED is a real outcome, not a failure to try. Missing hardware, missing credentials, no reproduction steps, no artifact to test: report it as BLOCKED and say exactly what would unblock it. A guessed PASS is worse than an honest BLOCKED.

## Re-QA

A ticket back in QA has usually changed since your last verdict. Read the previous verdict, read what changed, then:

1. Test the behaviour that failed or blocked last time, first.
2. Test the original acceptance criteria again. A fix for the reported symptom often breaks something the first cycle passed.
3. Post a new comment.

## Common mistakes

| Mistake | What it costs |
|---|---|
| Running the test suite and calling it QA | The bug ships. CI already passed, that is why it is here |
| Claiming without reading the latest comments | Duplicate QA, two conflicting verdicts |
| Treating an old claim as a live one | The ticket sits in QA for days and nobody tests it |
| A verdict with no proof | Nobody can act on it or check it later |
| Editing the previous verdict | The QA history is gone |
| Fixing the bug you found | Out of scope, and now the diff needs QA too |
| Guessing PASS because the environment was awkward | A false PASS is the most expensive thing QA can produce |

## Style

Concise. No em dashes. State observed behaviour separately from expected behaviour, and never blur the two. Read the existing comments before posting so you do not repeat a comment already on the ticket.
