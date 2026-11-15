---
name: merge-pr
description: 'Merge a GitHub PR now, or turn on automerge, after one question that shows what still blocks it. Use for "merge this PR", "merge #N", "ship it", "turn on automerge". The pr-board pane''s Merge button runs this.'
argument-hint: '[pr number | owner/name#N | URL]'
allowed-tools: Bash, AskUserQuestion
---

# Merge PR

Speed matters: ask in your first reply, then act in a single call. The facts
below were collected when this skill loaded, so do not run anything before the
question. Do not re-derive or override the scripts' decisions.

## Facts

!`"${CLAUDE_SKILL_DIR}/scripts/pr-facts.sh" $ARGUMENTS 2>&1`

If the facts show `error:`, ask me which PR in plain text, then run
`scripts/pr-facts.sh <pr>` and continue with its output.

## Step 1: Route on `NEXT`

| `NEXT` | Do |
|--------|----|
| `stop` | Show `STOP_REASON` and stop. |
| `ask`  | Step 2. |

## Step 2: Ask once

Write `#<PR_NUMBER> <PR_TITLE> (<AUTHOR>, <REPO>)`, then `CI: <CI_STATE>`, then
each `BLOCKERS` line as a bullet (or "Nothing blocks the merge." when empty). If
`AUTO_MERGE_ON=yes`, add "Automerge is already on."

Then make **one** AskUserQuestion call, header `Merge`, question "Merge
#`<PR_NUMBER>` at `<first 8 of HEAD_SHA>`?", with only the two `MERGE_OPTIONS`, in
order, the first one marked "(Recommended)": `merge-now` → "Merge now",
`automerge` → "Enable automerge", `not-now` → "Not now". Never add the merge
option the script left out.

## Step 3: Apply in one call

For "Not now", stop. Otherwise run, as one command on its own:

```bash
"${CLAUDE_SKILL_DIR}/scripts/apply.sh" <PR_URL> --merge <now|auto> --expected-head <first 8 of HEAD_SHA>
```

`now` for Merge now, `auto` for Enable automerge. Where automerge is allowed,
both merge at once if GitHub allows it and otherwise wait for its requirements.
If the PR moved since the question, `apply.sh` stops: show its error and do
nothing else. If `RESULT=failed`, show `ERROR` and stop; do not retry or offer
the other option.

## Output

One line: `RESULT` (`merged`, `auto-enabled`, `auto-already`), then `PR_URL`.

## Scripts

| Script | Changes GitHub | Notes |
|--------|----------------|-------|
| `scripts/pr-facts.sh` | no | state, CI, review, threads, `NEXT`, `RECOMMEND`, `BLOCKERS` |
| `scripts/apply.sh` | yes | `--dry-run` prints the gh command instead; never uses `--admin` |
| `scripts/lib.test.sh` | no | tests for the decision functions in `scripts/lib.sh` |
