---
name: pr-classifier
description: Classify pull requests or branches as good / needs-changes / bad / undecided by walking a chain of intent anchors — Sentry issue → Seer RCA → PR description → code — and flagging where the chain breaks. Also groups each PR's commits into pre- and post-feedback sets. Use when asked to "classify these PRs", "score my PRs", "which PRs went off the rails", "did the code match the description", "batch review my PR history", "build the PR corpus", or to measure how often agent-authored PRs drift from their own plan.
allowed-tools: Bash, Read, Grep, Glob, AskUserQuestion
---

# PR classifier

Grade a PR against the intent it claims to serve. Every stage is a script; the model is
called only where judgement is genuinely needed, and never for arithmetic.

Full design and the evidence behind every choice: `PLAN.md`. Read it before changing a
threshold or a prompt — most of the obvious ideas were already tried and measured.

## Pipeline

| Stage | Script | Cost | Does |
|---|---|---|---|
| 1 | `harvest.mjs` | GitHub only | Search + one GraphQL call per PR into a cache |
| 2 | `timeline.mjs` | free, offline | Bot filter, pre/post-feedback commit split, evidence |
| 3 | `triage.mjs` | free, offline | Fail-fast gates, work orders, AGENTS.md scoping |
| 4 | `classify.mjs` | ~2 cents/PR | The `description -> code` link, via Haiku |
| 5a | `conventions.mjs` | ~3 cents/PR | The `conventions` link: AGENTS.md + frontend-conventions rules |
| 5b | `verdict.mjs` | free | Aggregate links into one verdict |
| 6 | `label.mjs` / `eval.mjs` | ~25 cents/PR | Gold labels and scoring |

```bash
zx scripts/harvest.mjs --authored 200 --reviewed 100     # ~60s for 300 PRs, incremental
zx scripts/timeline.mjs
zx scripts/triage.mjs --population agent-authored --fetch-diffs --limit 30
zx scripts/classify.mjs --population agent-authored --limit 25 --run --concurrency 6
zx scripts/conventions.mjs --population agent-authored --limit 25 --run --concurrency 6
zx scripts/verdict.mjs --verbose
zx scripts/label.mjs && zx scripts/eval.mjs --verbose    # only when re-measuring
```

`classify.mjs` defaults to a dry run that renders prompts and prices the batch without
calling anything. Add `--run`.

Cache lives in `~/.cache/pr-classifier/`. Harvest re-fetches only when `updatedAt` changes.

## Facts that cost real time to discover

- **`MAX_THINKING_TOKENS=0` is mandatory** for the `claude -p` backend. Thinking was 94% of
  output tokens, 11x the latency, and made answers *worse* on this task. `--effort low`
  does not substitute. See [[reference_claude_p_batch_classify]].
- **With thinking off, the model writes prose before the JSON.** Never assume the reply is
  JSON — `parseVerdict` scans for balanced top-level objects and takes the last that parses.
- **The corpus is bimodal by author.** Anchor rate is 9% on ryan953's own PRs and 73% on
  agent-authored ones. The full ladder only runs on the agent slice; route on population
  before spending anything.
- **`getsantry` is the stale-PR cleanup bot** ("gone three weeks without activity").
  Exclude those. Other non-feedback bots: `github-actions`, `linear-code`, `cursor`,
  `codecov`, `sentry-io`, `seer-by-sentry`. Mine `linear-code` for the issue key first.
- **A rebase rewrites `committedDate`**, making pre-feedback work look like a response to
  feedback. Compare `authoredDate`. The guard fires on 9% of PRs.
- **~34% of closed PRs are `superseded`, not rejected.** Scoring them negative teaches the
  wrong lesson.
- **Evidence is two axes.** `coherence` (can the ladder run: description + diff) and
  `reception` (how it landed: comments + outcome). Only coherence gates — 44 PRs have a
  rich description and a small diff but zero comments, and are perfectly judgeable.
- **No embeddings.** Both AGENTS.md files together are 12.7 KB; inline them.
  `frontend-conventions` already has an exact regex gate, which beats retrieval here.

## Output contract

Stages emit **ordinal** judgments only — `match` / `partial` / `mismatch` / `unclear` plus
low/medium/high. The orchestrator computes every number. Never ask a model for a
probability: 20-odd gold labels cannot calibrate two digits, and cheap models anchor on
0.7/0.8/0.85 rather than measuring.

`verdict.mjs` applies per-link severity caps (a convention violation never reaches `bad`
alone), treats an abstaining link as silence rather than a vote for `good`, and demands
medium confidence before saying `good` while accepting a flag at any confidence. A false
`needs-changes` costs one glance; a false `good` ships a defect.

It also returns **`incomplete`** when a link the work order marked `ready` never produced a
judgment. A check that did not run is not a pass. Because the `conventions` link is not
built, most frontend PRs land on `incomplete` rather than `good` — that is correct, and it
is what the number should say until that link exists.

## State, honestly

Built and measured: stages 1-6 for the `description -> code` link, plus a single-PR path
(`harvest.mjs --pr <url>`, `--key` on triage and classify). On 20 agent-authored PRs the
link reached 80% exact agreement with a stronger Opus pass, 60% flag precision, 75% recall.

The `conventions` link is built (`conventions.mjs`). It reuses the `frontend-conventions`
rule docs and its exact regex gate table rather than that skill's subagent fan-out — the
fan-out suits reviewing one branch interactively, but is far too expensive per PR for a
batch classifier, and the gate is deterministic either way. The scoped AGENTS.md files come
from the work order. Capped at `needs-changes`.

A PR still lands on `incomplete` whenever some ready link has not been run yet, so run both
`classify.mjs` and `conventions.mjs` before reading a `good`.

Do not quote those numbers as settled. n=20, the intervals are wide (precision 23-88%),
and the prompt fix that produced them was tuned on the same 20 PRs it was scored against.
A held-out sample, ideally part-labelled by hand, is the next step.

Not built yet: `issue -> RCA` and `rca -> description`, which need a Sentry issue fetch.
Triage marks them `blocked`, so they never silently count as passes.

Single PR: `zx scripts/harvest.mjs --pr <url>` then `timeline`, `triage --key N
--fetch-diffs`, `classify --key N --run`, `conventions --key N --run`, `verdict`.
