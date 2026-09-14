---
name: weekly-done-summary
description: Write the "what shipped last week" section of the Kairos planning meeting. Use when someone asks for a weekly recap, a done summary, a sprint or planning-meeting update, or "what did we ship last week" for the kairos-io org. It covers DONE only (merged PRs, closed issues, releases) for Monday to Sunday of the week before today, and deliberately leaves blocked, in-progress and new tickets to the rest of the agenda. It reports value and direction, never a list of every PR. Do not use it for a release changelog or for a single repository's history.
---

# Weekly done summary

The planning meeting used to walk every merged PR and closed issue one by one. That is slow, and it crowds out the part of the meeting only humans can do: deciding what is blocked, what continues, and what starts next.

This skill produces the **done** half as one short issue on `kairos-io/kairos`, so the meeting can start at the second half.

## Three rules that decide everything else

1. **Value over detail, and short.** One bullet per theme. One or two sentences in it. The reader needs to know a line of work moved and why it matters, not the PR number that moved it. Detail belongs in the collapsed references, never in the body.
2. **Everything connects to something bigger.** A fix belongs to a release, to a feature line, or to the backlog trend. A fact with no connection gets cut.
3. **Newcomers get named and cheered.** A first contribution is the single highest-leverage thing in the summary. It is the only place where being specific is worth the space.

Write it for someone reading on a phone, five minutes before the meeting.

## Step 0: check nobody already filed it

`ci-robbot` files a recap automatically, titled `Recap: what shipped <dates>`. Look before you write:

```sh
gh issue list --repo kairos-io/kairos --state all --limit 20 --search "Recap: what shipped" \
  --json number,title,author,createdAt
```

If one exists for your window, **do not close it and do not rewrite it.** Its scope is the `kairos` repo only, listing every PR inline. This skill's scope is the whole org, grouped by theme. They are complementary, so file yours and cross-link both ways in a comment on each.

## Step 1: fix the window

Monday 00:00 UTC to Sunday 23:59 UTC of the week **before** today. Never a rolling seven days: the meeting needs the same boundary every time, or week-to-week numbers do not compare.

```sh
START=$(date -u -d 'last monday - 7 days' +%F 2>/dev/null || date -u -v-mon -v-7d +%F)
END=$(date -u -d "$START + 6 days" +%F 2>/dev/null || date -u -v-mon -v-1d +%F)
echo "$START..$END"
```

State the window in the title. Confirm it with the requester if today is a Monday, because "last week" is ambiguous then.

## Step 2: pull the raw data

Five queries. Everything else is derived from them.

```sh
W=$START..$END

# 1. merged PRs
gh search prs  --owner kairos-io --merged --merged-at "$W" --limit 300 \
  --json repository,number,title,author,url

# 2. closed issues
gh search issues --owner kairos-io --closed "$W" --state closed --limit 300 \
  --json repository,number,title,author,labels,url

# 3. issues opened in the window (for the backlog trend)
gh search issues --owner kairos-io --created "$W" --limit 300 --json repository,number

# 4. open issues right now (the denominator)
gh search issues --owner kairos-io --state open --limit 1 --json number | wc -l   # or read total from the API

# 5. releases published in the window, per active repo
for r in kairos AuroraBoot kairos-operator hadron cluster-api-provider-kairos \
         cluster-api-provider-kairos-fleet kairos-docs; do
  gh release list --repo "kairos-io/$r" --limit 20 \
    --json tagName,publishedAt,isPrerelease
done
```

If `gh` is unavailable or unauthenticated, the same data is on the public REST search API:
`https://api.github.com/search/issues?q=org:kairos-io+is:pr+is:merged+merged:$START..$END&per_page=100`.
Page it: search returns 100 per page and reports the real count in `total_count`. Unauthenticated is 10 searches per minute, which is enough for this skill if you do not retry.

## Step 3: split the authors three ways

A raw PR count says almost nothing in this org, because most PRs are not written by hand. Split the authors before you count anything:

- **Human.** A person typed it.
- **Agent.** An AI lane authored it under its own account. Today that is `ci-robbot`, `mauro-agent`, `itxaka-agent` and `Copilot`. **Check the PR titles before you classify an account.** `ci-robbot` looks like a version bumper and is not: it authors real fixes, and treating it as noise throws away most of the week.
- **Dependency and release chores.** `renovate[bot]`, `dependabot[bot]`, and the release bumps from `github-actions[bot]`.

Report it as **total, with the agent share in parentheses**: `135 PRs merged (81 agent)`. Put the human and chore counts in the second cell of the row. One headline number, one honest breakdown, no arithmetic for the reader.

**Issues filed by an agent are signal, not noise.** They are bugs a human or another agent then fixed. Count them in the closed-issue total.

## Step 4: find the newcomers

For every human who had a PR merged in the window, count what they merged in the org **before** the window:

```sh
gh search prs --owner kairos-io --merged --author "$U" --merged-at "<$START" --limit 1 --json number
```

- **Zero** means a first contribution. This person leads the Cheers section by name.
- **A handful** means an occasional community contributor. Name them in one sentence.
- **Dozens** means a regular. Their work goes in the themes, not in Cheers.

Also check issue authors: a first-time bug report that got fixed in the same week is worth a line, and so is a new entry in `ADOPTERS.md` or a new adoption issue.

The best story to look for: **the same person reported the bug and sent the fix.** Say so plainly when it happens.

## Step 5: do the backlog arithmetic

```
opened   = count of issues created in the window
closed   = count of issues closed in the window
net      = opened - closed
open_now = open issues today
open_then = open_now + closed - opened
percent  = (open_now - open_then) / open_then
```

Report it as `open_then to open_now, down X%`. If the net went the wrong way, say that too, in the same neutral tone. An honest number that moves up once is worth more than a number nobody trusts.

**Add one sentence of quality.** Closing forty stale tickets is not the same as closing five long-standing feature requests. Check the creation dates of the closed issues: when several are more than a year old, say so, because that is what makes the drop real rather than cosmetic.

## Step 6: group into four to six themes

Read the merged PR titles and the closed issue titles together, and cluster them. Do not group by repository. Group by what a user would notice.

Themes that recur in this org, as a starting point and not a checklist:

- a release going out, and what it unblocks
- one feature line getting most of the week's attention
- long-standing requests finally closing
- crash-class and reliability fixes, often QA-bot found
- first-touch user experience: the web UI, the installer, the docs
- supply chain and CI hygiene that nobody filed a ticket for

**Each theme is one bullet: a bold lead phrase, then one or two sentences.** Name the concrete thing that changed, then what it means. Prose paragraphs are the failure mode here. They look thorough and read as a wall, and nobody scans them five minutes before a meeting.

Cut any theme you cannot finish with a "so what".

## Step 7: build the reference appendix, with a script

Every PR and issue counted in the table must appear at the bottom, grouped under the same theme headings, inside collapsed `<details>` blocks. GitHub renders them in issue bodies.

```markdown
<details>
<summary><b>Cluster API</b> (12 PRs, 2 issues)</summary>

- kairos-io/cluster-api-provider-kairos#96 fix: support any CAPI-conformant provider (wrkode)
- closed #3533 Add First-Class Support for kubeadm Provider

</details>
```

**Do not assemble this by hand.** Write a throwaway script that holds a theme-to-item map and then **fails loudly** on anything unassigned or assigned twice, and refuses to emit until both lists are empty. On the run this skill was written from, that check caught one orphaned PR and one duplicated issue that hand-checking had missed. The totals in the appendix must reconcile exactly against the table at the top, or the numbers are assertions rather than evidence.

Two details that matter:

- **Strip the `@` from author names in the appendix.** With it, every one of ~190 lines pings a bot account. Handles keep the `@` in Cheers, where the notification is the point.
- **List the dependency chores too.** They are collapsed, so completeness is free.

## Step 8: file it as an issue

The output is a **GitHub issue on `kairos-io/kairos`**, not a document. It belongs where the team already reads, it takes comments, and it joins the existing `Recap: what shipped ...` series.

```sh
gh issue create --repo kairos-io/kairos \
  --title "Recap: what shipped <Mon D> – <Mon D> <YYYY>" \
  --body-file recap.md
```

- Match the existing series title format so the recaps stay greppable.
- Heading anchors are unreliable in issue bodies. Write "listed under References at the bottom", not a `[link](#references)`.
- Run the project's public-content check on the body before filing.
- If a person's own account is used to post rather than an agent account, add the AI-assistance disclosure line, so the reader knows a human attends.

## Step 9: the body template

```markdown
Window: **<START> → <END>** (Mon to Sun, UTC). **Done only**: blocked, in progress
and new work are separate agenda items. Every item counted is listed under
References, collapsed.

| | |
|---|---|
| **N releases** | <tag list with repos> |
| **C issues closed, O opened** | backlog <then> to <now>, down X% |
| **P PRs merged (A agent)** | <human> human, <chores> dependency and release chores |

## What moved

- **<Theme lead>.** One or two sentences: what changed, then what it means.

(four to six bullets, no more)

## Cheers

- **@<first-timer> landed their first Kairos contribution.** What they fixed, plainly. Welcome them.
- <one line each for occasional contributors, new bug reporters, new adopters>

## References

<the collapsed blocks from Step 7>
```

## House rules for the prose

- **No em dashes.** Use a period, a comma, a colon, or parentheses. This is the Kairos project voice and it applies here.
- Active voice. Name the actor.
- Short sentences. Around 20 words.
- No PR numbers in the themes. Issue numbers are allowed when the point is the age of the ticket ("open since 2023").
- Handles in Cheers are written as `@handle` so the person sees the mention.
- Do not editorialise about work that did not happen. This document only covers done.
- **Hard cap: 250 words above the references.** Count them. The first draft will be double that, and cutting it is the job, not an optional polish pass.
- Bullets, not paragraphs. If a bullet needs a third sentence, the detail belongs in the references.
- Over the cap means a theme gets cut, not compressed. Six themes that say nothing beat three that say something only if you enjoy being ignored.

## What this skill does not do

- It does not cover blocked or in-progress work. That is the meeting's job.
- It does not produce release notes. Releases are named here, never itemised.
- It does not judge or rank people's output. It names first contributions and nothing else about individuals.
- It does not replace `ci-robbot`'s automatic recap. That one is the per-PR changelog for the `kairos` repo. This one is the org-wide view for the meeting. Both can exist for the same week.
