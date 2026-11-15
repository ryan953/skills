---
name: getsentry-tests
description: 'Add the "Trigger: getsentry tests" label to a getsentry/sentry PR so getsentry CI runs on it; --rerun relabels to send it again. Use for "run getsentry tests", "add the getsentry label", "trigger getsentry CI on #N". The pr-board pane''s getsentry tests button runs this.'
argument-hint: '[pr number | URL] [--rerun]'
allowed-tools: Bash, AskUserQuestion
---

# getsentry tests

Adding `Trigger: getsentry tests` to a PR in getsentry/sentry makes its
`getsentry dispatch` workflow run getsentry's test suite against the PR's code.
A push removes the label, so it has to go back on for each new head.

## Facts

!`"${CLAUDE_SKILL_DIR}/scripts/run.sh" facts $ARGUMENTS 2>&1`

If the facts show `error:`, ask me which PR in plain text, then run
`scripts/run.sh facts <pr>` and continue with its output.

## Route on `NEXT`

| `NEXT` | Do |
|--------|----|
| `stop` | Show `STOP_REASON` and stop. |
| `apply` | Run step 2 right away; don't ask. |
| `ask` | The PR comes from a fork, and the label runs getsentry CI, with its secrets, on that code. Make one AskUserQuestion call, header `getsentry`, question "#`<PR_NUMBER>` by `<AUTHOR>` is from a fork. Run getsentry CI on its code at `<first 8 of HEAD_SHA>`?", options `Add the label` and `Not now`. On `Not now`, stop. |

## Step 2: Apply

As one command on its own (add `--rerun` when `RERUN=yes`):

```bash
"${CLAUDE_SKILL_DIR}/scripts/run.sh" apply <PR_URL> --expected-head <first 8 of HEAD_SHA>
```

If the PR moved since the facts were read, it stops: show its error and do
nothing else.

## Output

One line: "Added `Trigger: getsentry tests` to #N" (or "Relabelled" when
`RELABELLED=yes`), then `PR_URL`.

## Scripts

| Script | Changes GitHub | Notes |
|--------|----------------|-------|
| `scripts/run.sh facts` | no | repo, state, fork, label, `NEXT` |
| `scripts/run.sh apply` | yes | `--dry-run` prints the gh commands instead |
| `scripts/lib.test.sh` | no | tests for the decision functions in `scripts/lib.sh` |
