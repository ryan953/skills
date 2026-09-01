# pr-classifier — implementation plan

Status: harvest + timeline built and validated over 301 PRs. Written 2026-08-28.

Classify a pull request or branch as `good`, `needs-changes`, `bad`, or `undecided`.
Walk a chain of intent anchors: Sentry issue -> Seer RCA -> PR description -> code.
If any link breaks, the PR is not good.

---

## 0. Evidence that shapes this design

Measured over the full harvested corpus: **299 PRs**, `getsentry` org, 0 fetch failures.
Numbers marked (rev) correct an earlier estimate taken from a 60-PR sample that proved
unrepresentative.

| Measurement | Result | Effect on the design |
|---|---|---|
| Corpus harvested | 299 PRs | 244 merged, 33 closed, 17 superseded, 5 excluded |
| PRs with any upstream anchor | 65 of 299 (22%) | (rev) Better than the 10-15% first estimated. |
| — authored by ryan953 | 17 of 200 (**9%**) | The ladder's top rungs are absent here. |
| — authored by an agent | 38 of 52 (**73%**) | The full ladder runs here. See section 4a. |
| — authored by another human | 10 of 47 (21%) | Mixed. |
| Sentry issue links | 38 | (rev) All from the PR body, as `Fixes [SHORT-ID](...?seerDrawer=true)`. |
| Linear linkbacks | 22 | The `linear-code` bot comment carries the key. |
| PRs the `getsantry` bot closed | 5 | Excluded, as planned. |
| Self-closed as superseded | 17 of 50 closed (34%) | Confirmed. Detector verified by hand. |
| Commits needing the rebase guard | 27 of 299 (9%) | See below. Without it, 11 PRs flip verdict. |
| PRs with an empty description | 25 | The only genuinely unjudgeable class. |
| Both `AGENTS.md` files | 12.7 KB | Small enough to inline. No embeddings. |

### The corpus is bimodal by author, and that is the main structural finding

The anchor rate is not uniform. It is 9% on your own PRs and 73% on agent-authored ones.
So `issue -> RCA -> description -> code` is not uniformly sparse. It is **fully populated
on exactly the agent-authored PRs and near-absent on your hand-written ones**.

The classifier must route on this, not run one uniform pipeline. See section 4a.

### The rebase guard

A rebase rewrites `committedDate`. Without a guard, work authored *before* feedback looks
like a response *to* that feedback. Comparing `authoredDate` against `committedDate`
catches this. It fired on 27 of 299 PRs, and 11 of those would have flipped from
"never responded" to "responded". Both dates are now fetched for this reason.

## 1. Cache the corpus

Script: `scripts/harvest.mjs` (zx).

Two searches, both states, merged and closed:

```
gh search prs --author=ryan953      --owner=getsentry --state=closed
gh search prs --reviewed-by=ryan953 --owner=getsentry --state=closed
gh search prs --commenter=ryan953   --owner=getsentry --state=closed
```

Then one GraphQL call per PR. Verified: 299 PRs in 59 s, 0 failures, ~12 KB cached each.
`files` and `authoredDate` are fetched here so that triage needs no network at all.

```graphql
query($owner:String!,$repo:String!,$num:Int!){
  repository(owner:$owner,name:$repo){
    pullRequest(number:$num){
      number title url state isDraft
      createdAt updatedAt closedAt mergedAt
      baseRefName headRefName additions deletions changedFiles body
      author{login} mergedBy{login} labels(first:20){nodes{name}}
      timelineItems(last:5,itemTypes:[CLOSED_EVENT]){nodes{... on ClosedEvent{createdAt actor{login}}}}
      commits(first:100){totalCount nodes{commit{oid committedDate authoredDate messageHeadline}}}
      comments(first:100){nodes{createdAt author{login} body}}
      reviews(first:50){nodes{createdAt state author{login} body
        comments(first:50){nodes{createdAt path body}}}}
      closingIssuesReferences(first:5){nodes{number title url body}}
      files(first:100){nodes{path additions deletions}}
    }
  }
}
```

Cache layout:

```
~/.cache/pr-classifier/
  prs/<owner>__<repo>__<num>.json   raw payload
  diffs/<owner>__<repo>__<num>.diff fetched only when a PR reaches stage 3
  index.json                        slim rows for fast iteration
  labels/gold.jsonl                 hand labels for the eval
```

Re-fetch only when `updatedAt` changes. The diff is fetched lazily, never during harvest.

**Exclusion rule.** Drop the PR when the `ClosedEvent` actor is `getsantry`, or when a
`getsantry` comment matches `/gone three weeks without activity/`. This is the cleanup bot.

## 2. Filter the bots

Bot logins seen live: `getsantry`, `github-actions`, `linear-code`, `cursor`,
`codecov`, `codecov-commenter`, `sentry-io`, `seer-by-sentry`.

Bot body markers seen live: `<!-- TYPE_COVERAGE_DIFF -->`, `<!-- STORIES_PREVIEW -->`,
`<!-- FRONTEND_BACKEND_WARNING -->`, `<!-- craft-changelog-preview -->`, `<!-- linear-linkback -->`.

Bot comments are not feedback. Remove them before you group the commits.
But mine two of them first:

- `linear-code` gives the Linear issue key, for example `CW-771` or `ENG-7768`.
- `sentry-io` and `seer-by-sentry` give the Sentry issue and the Autofix or RCA link.

## 3. Group the commits

Script: `scripts/timeline.mjs` (zx). Pure data. No model call.

Merge all events into one list and sort by timestamp:

- commit events, from `committedDate`
- feedback events: human comment, human review, merge, close

Feedback polarity:

| Event | Polarity |
|---|---|
| Review `APPROVED`, merge | support |
| Review `CHANGES_REQUESTED`, inline review comment | change-request |
| Human comment, no request | support or neutral, set by stage 3 |
| Close without merge | negative |

**Extra polarity `superseded` — settled, and implemented.** 17 of 50 closes (34%) were the author's own,
with a reason such as "Superseded by #122900", "Landed directly on main as c0aa2ce",
or "Closing in favor of folding this into #121031". The code was not rejected. It moved.
If you score these as negative, the training signal is wrong.
Detect it: the closer is the author, and the last human comment matches
`/superseded|landed directly|in favor of|folding (this )?into/i`.
Treat `superseded` as neutral and keep it out of the bad set. Detector checked by hand
against all 17 matches.

Output per PR:

```json
{ "firstFeedbackAt": "...",
  "preCommits": ["oid", "..."],
  "postCommits": ["oid", "..."],
  "feedbackEvents": [{"at": "...", "kind": "review", "polarity": "change-request", "actor": "..."}],
  "outcome": "merged | closed | superseded | excluded" }
```

## 4. The classifier chain

Do not treat the chain as a required sequence. Treat it as a ladder of intent anchors.
Each rung is optional. Grade only the pairs where both rungs exist.

```
[Sentry issue] -> [Seer RCA] -> [PR description] -> [code]
     22%             17%             92%             100%     <- whole corpus
     73%             73%             99%             100%     <- agent-authored only
```

| Link | Question | Fires on |
|---|---|---|
| issue -> RCA | Does the RCA explain the real error in the issue? | 22% (73% of agent PRs) |
| RCA -> description | Does the PR claim to do what the RCA proposed? | 17% |
| description -> code | Does the diff do what the description says? | 92% |
| code -> conventions | Does the diff obey AGENTS.md and the frontend conventions? | 100% of JS/TS |

The verdict is the worst link. A missing anchor is a skip, not a penalty.
`description -> code` carries about 78% of the corpus alone. Build that link first and best.

## 4a. Route on population before you spend anything

Three populations, decided for free from the author login and the PR body stamp:

| Population | n | Anchored | Which links can run |
|---|---|---|---|
| `agent-authored` | 52 | 73% | The full ladder, all four links. |
| `reviewed-human` | 47 | 21% | Usually description -> code + conventions. |
| `own` | 200 | 9% | Almost always description -> code + conventions. |

The `agent-authored` slice is where the classifier earns the most: those PRs carry a
Sentry issue and a Seer RCA, so every rung exists and the whole chain is checkable.
It is also the slice that serves the standing goal of auto-labelling agent changes as
correct and proper, instead of sending them to a human.

## 5. Stages, in fail-fast order

Each stage returns a small strict JSON verdict. The orchestrator keeps only the JSON.
It never holds a diff or an issue body in its own context.

| # | Stage | Model | Stops when |
|---|---|---|---|
| 0 | Exclusions, bot filter, timeline | none | `getsantry` closed it |
| 1 | Extract links: Linear, Sentry, Seer, GitHub | none | never, it only annotates |
| 2 | Diff triage: size, file types, generated files | none | diff is too large or is all generated |
| 3 | description -> code coherence | Haiku 4.5 | the diff contradicts the description |
| 4 | issue -> RCA -> description | Haiku 4.5 | skipped when no issue link |
| 5 | Conventions: AGENTS.md + frontend-conventions | Haiku 4.5 | never, it only adds findings — BUILT as `conventions.mjs` |
| 6 | Adjudicate a borderline or split result | Sonnet 5 | final |

Gate 0 also returns `undecided` at once for a PR with zero human comments that the author
closed quickly. There is no feedback signal in it. Many sampled closed PRs are this shape.

Cost controls:

- Cap the diff at 60 KB. Drop lockfiles, snapshots, and generated files first.
- Pass each subagent only its own slice. Never the whole PR record.
- Run stages 3, 4, and 5 in parallel once stage 2 passes.
- Stage 6 runs only when the stages disagree.

## 5a. Model access — use the `claude` CLI, not an API key

Settled 2026-08-28. This machine has no `ANTHROPIC_API_KEY` and no `ant` CLI, but
`claude -p` runs headless on the existing Claude Code auth, so it needs no setup at all.

`classify.mjs --backend cli` (the default) shells out to:

```
MAX_THINKING_TOKENS=0 claude -p "<user>" --model haiku \
  --system-prompt "<system>" --output-format json --allowedTools ""
```

**`MAX_THINKING_TOKENS=0` is not optional.** Measured on one PR:

| | thinking on | thinking off |
|---|---|---|
| output tokens | 1523 (94% thinking) | 75 |
| latency | 16.9 s | 1.5 s |
| verdict | `unclear` (wrong) | `match` (right) |

Thinking cost 11x the latency and made the answer worse on a task that is a lookup, not a
reasoning problem. `--effort low` does **not** substitute: it raised both cost and thinking
tokens.

Two consequences of running thinking-off, both handled:

1. **The model writes its reasoning as visible prose before the JSON.** Never assume the
   reply is JSON. `parseVerdict` scans for balanced top-level objects and takes the last
   one that parses. Before this fix, 2 of 3 verdicts were `unparseable model output`
   masquerading as `unclear`.
2. **It over-asserts `mismatch` when it simply cannot see enough.** A diff shows changed
   lines, not whole files. The prompt now states that missing context is `unclear`, never
   `mismatch`. This moved a verified false positive (`sentry#121236`) from `mismatch/high`
   to `partial/medium`.

Measured over 25 agent-authored PRs, concurrency 6: **1.8 s/PR wall, $0.018/PR, 0 errors**,
about $4.75 for all 261. The API backend is ~10x cheaper per call ($0.0017/PR) because it
skips the ~19K-token Claude Code harness prompt — keep `--backend api` for a full-corpus
run if a key ever appears, but the CLI is the default because it needs nothing.

Prompt caching works across separate `claude -p` invocations, so the first N calls at
concurrency N pay cache-creation and the rest read.

## 6. Why there are no embeddings

You asked about an index or local embeddings. The measurements say you do not need one.

- Both AGENTS.md files together are 12.7 KB. Put them in the prompt whole.
- `frontend-conventions` already maps diff content to rule docs with an exact regex table.
  That gate is free and exact. Semantic retrieval would be slower and less precise.
- `~/code/sentry-docs` has 5013 `.mdx` files, but this chain never asks a product question.

Keep a fallback in reserve: if rule lookup ever gets too large, use ripgrep over the
headings first. Add embeddings only if ripgrep fails.

## 7. Files

```
~/.claude/skills/pr-classifier/
  SKILL.md               not yet written
  PLAN.md                this file
  plan.html              the published artifact
  scripts/harvest.mjs    BUILT  search + GraphQL + cache        (299 PRs / 59 s / 0 fail)
  scripts/timeline.mjs   BUILT  bot filter + pre/post + evidence (offline)
  scripts/triage.mjs     BUILT  free gates + work orders         (offline, 87% reach a model)
  scripts/classify.mjs   BUILT  description -> code, Haiku 4.5   (dry run only so far)
  scripts/eval.mjs       todo   score the classifier vs gold labels
  labels/gold.jsonl      todo   hand labels
```

Cache: `~/.cache/pr-classifier/` — `prs/`, `diffs/`, `timeline/`, `prompts/`, `verdicts/`,
plus `index.json`, `timelines.json`, `workorders.json`, `verdicts.json`.

Measured cost for stage 3 on Haiku 4.5: **$0.0017 per PR**, about **$0.43** for all 261
PRs that reach a model. The system prompt is cached, and bot footers are stripped from
the description before sending.

## 8. How it is proved — and the first measurement

`label.mjs` makes gold labels, `eval.mjs` scores stage 3 against them, `verdict.mjs`
aggregates links into the final classification.

### The gold labels are not human labels

They come from a deliberately stronger pass: a more capable model, thinking ON, the full
diff with no 24 KB cap, and an instruction to verify claim by claim. Cost $0.248/PR
against $0.018 for stage 3.

This measures whether the cheap stage-3 view is good enough. **It cannot catch an error
both passes share.** Treat it as an upper bound on agreement, not as truth.

Sampling is stratified: every PR stage 3 flagged, plus a sample it called `match`, so the
eval sees false negatives as well as false positives.

### First measurement, n = 20 agent-authored PRs

| | before the fix | after |
|---|---|---|
| exact agreement | 65% [43-82%] | **80% [58-92%]** |
| flag precision | 50% [19-81%] | **60% [23-88%]** |
| flag recall | 75% [30-95%] | 75% [30-95%] |
| false positives | 3 | 2 |
| harsher than gold | 5 | 3 |

The measured failure mode was **over-flagging**, and it was interpretable: stage 3 raised
`partial` when the description's *rationale* was loosely worded, or when it could not fully
verify a claim — not when the code actually diverged. One targeted prompt change (judge
what the code does, not how well the description explains itself; unverifiable is
`unclear`, not `partial`) moved agreement up with no loss of recall.

### Two caveats that matter

1. **n = 20 is small.** Every interval above is wide, and the precision change sits well
   inside the noise. The exact-agreement change is more suggestive but still not firm.
   Read the intervals, not the point estimates.
2. **The fix was tuned on the same 20 PRs it is scored against.** That is overfitting risk.
   The honest next step is a fresh held-out sample of labels, ideally with some labelled by
   hand, before trusting any of these numbers.

Aim: high precision on the flags, and never a confident `good` that is wrong. `undecided`
is the safety valve, but track its share — it is a cost, not a safe default.

## 9. Decisions — settled 2026-08-28

1. `superseded` is its own label. Treat it as neutral. Keep it out of the bad set.
2. Corpus scope: the `getsentry` org, 200 PRs authored plus 100 reviewed.
3. "Reviewed" includes PRs where you only commented. Use `--commenter` and `--reviewed-by`.

## 10. Decision — absolute headline, ordinal internals, free evidence score

Settled 2026-08-28. Emit an absolute label as the headline. Keep the per-link shape
underneath. Do not ask the models for probabilities.

### Why not a probability distribution over the four labels

The four labels are not one probability space. `good`, `needs-changes` and `bad` sit on a
severity axis, which is a real continuum. `undecided` is not on that axis. It states how
much we saw, not how good the PR is. One distribution over all four would mix an
object-level judgment with an epistemic one, so `undecided: 0.3` and `bad: 0.3` would not
share a meaning.

Split them into two axes:

- **verdict** — ordinal severity: `good -> needs-changes -> bad`
- **evidence** — how many rungs existed, how many human comments there were, whether the
  diff was reachable and under the cap

`undecided` is then not a fourth label. It is a suppressed verdict, used when evidence
falls below the threshold. This also separates the two opposite problems that `undecided`
hides today: no evidence (a flat low vector) and conflicting evidence (two near-equal
peaks). Collapsed to one word, those look identical. Kept as a vector, they do not.

### The models must not emit numbers

A cheap model asked to "rate 0 to 1" clusters on 0.7, 0.8 and 0.85. Those are anchoring
artifacts, not measurements. The same model asked "yes / mostly / no / cannot tell" is
reliable, because that judgment is one it can actually make.

Rule: **stages emit ordinal judgments; the orchestrator computes every number.** The
arithmetic lives in code, where you can read it, test it, and change it without a re-prompt.

Also, 30 gold labels cannot calibrate a two-digit probability. A published `0.72` promises
that about 72% of PRs scored 0.72 are bad. This sample size cannot support that promise.

### Evidence is free — and it is two axes, not one

`timeline.mjs` computes evidence deterministically, before any model runs. A model cannot
hallucinate the fact that a PR had no human comments.

The corpus forced a correction here. A single evidence score conflated two different
questions, and gated out 42 PRs that were perfectly judgeable:

- **coherence** — can the ladder run? Needs a description and a tractable diff. It does
  **not** need human comments.
- **reception** — how did it land? Needs comments, reviews, and an outcome.

These come apart on real data. 44 PRs have a rich description (median 1558 chars) and a
small diff (median 72 lines) but zero human comments. The `description -> code` link runs
on them fine. They are **silent, not unjudgeable**.

So only `coherence` gates. Low reception is a finding the classifier reports, never a
refusal to decide. That change alone cut the undecided rate from 19% to 9%, and the 9%
that remains is 25 PRs with a literally empty description plus 1 oversized diff — a class
that genuinely has no intent statement to check the code against.

A second correction: drop near-constant terms from any score. `outcomeKnown` is true for
~100% of a closed-PR corpus, so scoring it only added an offset and pushed 78% of PRs into
one band. Constants carry no information. This is the same fake-precision trap the section
warns about, and I walked into it once already.

### Fail-fast does not lower confidence

An early exit is the most confident output, not the least. The pipeline stopped because it
found something decisive. Record which links ran. Score confidence from the strength of the
finding, never from the count of completed stages. Backwards, the pipeline would punish
itself for being efficient.

### Per-link severity caps

Links do not vote equally. A conventions violation caps at `needs-changes`. A
description-to-code contradiction may reach `bad`. Each link declares its own cap, and the
verdict is the highest severity any link both asserts and is allowed to assert.

### `incomplete` — found by running the skill on one real PR

A link the work order marked `ready` but that never ran is **not** an abstention. It is a
check that did not happen. Treating the two alike let `verdict.mjs` return `good` for PRs
whose conventions link was never evaluated, because that link is not built yet.

That is precisely the expensive error this design exists to avoid, and the batch runs hid
it — they only ever exercised one link. `verdict.mjs` now compares the ready links against
the links that actually produced a judgment, and returns `incomplete` when any are missing.

The correction is large: of 26 classified PRs, `good` fell from 21 to **5**, and 16 became
`incomplete`. The 5 that remain have no frontend files, so the conventions link never
applied. Any `good` count elsewhere in this document that predates this section was
inflated by the same bug.

### Output shape

```json
{
  "verdict": "needs-changes",
  "confidence": "high",
  "evidence": 0.8,
  "links": [
    {"link": "description->code", "judgment": "partial",   "cap": "needs-changes"},
    {"link": "conventions",       "judgment": "match",     "cap": "needs-changes"},
    {"link": "issue->rca",        "judgment": "no-anchor"}
  ]
}
```

`evidence` is free and deterministic. `confidence` is ordinal. `links` is the per-link
vector the stages already produce. `verdict` is the argmax, suppressed to `undecided` when
evidence falls below the threshold.

Asymmetric thresholds are the point: demand high confidence before saying `good`, and
accept low confidence for `needs-changes`. A false `needs-changes` costs one human glance.
A false `good` ships a defect. The threshold is config, not prompt text, so the automation
rate is tunable without a re-prompt.

### Upgrade path

`links` is exactly the feature set a calibrated model would need. At 100 or more gold
labels, fit a small lookup or logistic over it and emit real probabilities. Retaining the
vector now is what makes that possible later. Building the probabilities now is what would
make them wrong.

### Expected finding

The conventions link will probably prove noisy. Watch it in the eval. It may end up
advisory-only rather than verdict-bearing. The per-link vector is what will show that,
instead of leaving you to guess.
