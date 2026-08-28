# Running the arm the cloud session could not

The 2026-08 pilot scored four merged Seer PRs and got 3 accepts + 1 correct
reject. Two things it could not do, both of which need your machine:

1. **The reject arm** — closed, unmerged Seer PRs. Their commit message is one
   subject line; the Root Cause / Solution text lives in the PR *description*,
   which only reaches git when a merge squashes it in. Needs the GitHub API.
2. **The probe wave** — proving the closing link by running a test that must
   fail against base. Needs the sentry toolchain.

Prerequisites: `gh auth status` clean, a clone at `~/code/sentry`, `jq`, and the
Sentry MCP available to whatever runs the skill.

## The short version

```bash
~/code/skills/skills/autofix-review/scripts/eval/pilot.sh \
  --repo-path ~/code/sentry --decider ryan953 --out ~/autofix-review-pilot
```

Probes are off by default. That first pass gets verdicts across the whole
sample; then re-run the few cases whose closing link you actually want measured
with `--probes`. With probes on, each case checks the shared worktree pair out at
base and at head and runs one test against each — minutes per case on a monorepo.

Cases run `--jobs` at a time (default 2). They are independent, but each one fans
out around sixteen subagents, so raising this mostly buys queueing: measured runs
at `--jobs 4` sat up to 53 minutes between gathering a case and writing its first
card. Lower it before you raise it. `--max-cases` (default 20) bounds the sample.

That runs all five stages, tees to `<out>/pilot.log`, and prints a summary short
enough to paste back. It fails loudly rather than quietly on the two ways this
harness produces nothing: an empty candidate list, and every case failing to run.
Add `--probes` to run the probe wave, drop `--decider` to widen past your own
calls. The stage-by-stage version follows if you want to drive it yourself.

## 1. Collect both halves of the seer arm

```bash
E=~/code/skills/skills/autofix-review/scripts/eval
cd ~/code/sentry

$E/collect.sh --repo getsentry/sentry --arm seer \
  --bot-author app/seer-by-sentry --decider ryan953 \
  --limit 100 --since 2025-06-01 --out raw.jsonl

wc -l raw.jsonl        # merged AND closed; if this is only merges, drop --decider
```

`--decider` keeps only PRs *you* merged or closed. Drop it to widen to the whole
team — the sample gets bigger and the labels stop being about one person's
judgement. Say which you did when you report the numbers.

## 2. Slice and label

```bash
$E/slice.sh --repo getsentry/sentry --from raw.jsonl --out sliced.jsonl
$E/label.sh sliced.jsonl > labelled.jsonl

jq -r '[.pr, .state, .label, .label_why] | @tsv' labelled.jsonl | column -t -s$'\t'
```

**Read that table before trusting any number it produces.** Two rules to check by
eye:

- A merged PR whose issue a *later* commit re-fixes is `REJECT_TRUTH`, not
  `ACCEPT_TRUTH` (`superseded_later`). The pilot's one disagreement was exactly
  this, and without the check the harness punishes the skill for being right.
- A close whose comment says the fix stopped mattering is `EXCLUDED` — the code
  was never judged.

`slice.sh` fills `issue_id` from the PR body. Where it comes back empty the
supersession check cannot run, so those rows are worth a look.

## 3. Run it, with probes on

```bash
$E/run.sh --cases labelled.jsonl --repo-path ~/code/sentry --out predictions.jsonl
```

With `--probes`, Wave 3 runs and the closing link is measured rather than
reasoned about; without it the run is labelled `scored: read-only`. `run.sh` drives `claude -p` per case when `claude` is on PATH.

For the probes themselves, the runner is per-surface:

```bash
# frontend
--runner 'pnpm jest --silent {}'
# backend
--runner 'pytest -q {}'
```

The gate that makes a probe worth anything: **it must FAIL against base.** One
that passes is `invalid` and gets discarded — it measured nothing. In the pilot
the first probe attempt did exactly that (too small a repro) and was thrown away
rather than reported.

## 4. Score

```bash
$E/score.sh --predictions predictions.jsonl --by-arm --reasons reasons.tsv
column -t -s$'\t' reasons.tsv
```

`reasons.tsv` puts each true reject beside what the human actually said.
**Read it by hand** — agreeing on "reject" for the wrong reason is a miss the
confusion matrix cannot see, and it is the usual way a rubric looks better than
it is.

## Getting the evidence straight from Sentry

Where the PR body is thin — which is every closed Seer PR — the better source is
the issue itself. Seer's autofix state carries the PR URL, so you can go the
other way: find the issue whose run produced PR #N, then build the evidence and
RCA cards from `mcp__sentry__analyze_issue_with_seer` rather than from prose the
bot wrote about itself.

That is strictly better input than the merged arm had, because the evidence stops
being the author's own account. It also un-collapses `L1`: on a `pr-body` case
the evidence and RCA cards come from one person's writing, so that link only ever
showed internal consistency (every `L1` agent in the pilot said so unprompted).

`trigger-autofix`'s `autofix_sweep.py` already reads
`GET /api/0/issues/{short_id}/autofix/` → `autofix.repo_pr_states`, which is the
PR-number-to-issue map you need.

## What to expect

- Four cases find broken rules; **they do not measure precision.** 50+ for that,
  and the closed arm will always be the thinner half.
- Reviewer nits count as rejects in the labels and are deliberately not rejects
  to this skill — they surface as false accepts. Adjudicate them out by hand.
- Report read-only and probe-scored runs separately. `score.sh` will not let you
  forget, but it will not stop you either.
