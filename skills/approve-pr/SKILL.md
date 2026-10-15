---
name: approve-pr
description: 'Approve a GitHub PR with my comment; for bot PRs, also add the getsentry tests label and offer merge or automerge. Use for "approve this PR", "approve #N", "LGTM this PR", or "approve and merge".'
argument-hint: '[pr number | owner/name#N | URL]'
allowed-tools: Bash, AskUserQuestion
---

# Approve PR

Speed matters: ask everything in your first reply, then act in a single call. The
facts below were collected when this skill loaded, so do not run anything before
the questions. Do not re-derive or override the scripts' decisions.

## Facts

!`"${CLAUDE_SKILL_DIR}/scripts/pr-facts.sh" $ARGUMENTS 2>&1`

If the facts show `error:`, ask me which PR in plain text, then run
`scripts/pr-facts.sh <pr>` and continue with its output.

## Step 1: Route on `NEXT`

| `NEXT` | Do |
|--------|----|
| `stop` or `done` | Show `STOP_REASON` and stop. |
| `apply` | Skip to step 3 with no flags (already approved, automerge on). |
| `ask` | Step 2. |

## Step 2: Ask once

In one reply, write `#<PR_NUMBER> <PR_TITLE> (<AUTHOR>, <AUTHOR_CLASS>)`, then
`SUMMARY` exactly as printed when `ASK_MERGE=yes`, then make **one**
AskUserQuestion call holding every question that applies:

| When | Header | Question | Options |
|------|--------|----------|---------|
| `ASK_COMMENT=yes` | `Comment` | "Approve `<AUTHOR>`'s PR #`<PR_NUMBER>` at `<first 8 of HEAD_SHA>`?" — when `MY_COMMITS` > 0, add "It includes your commits: `<MY_COMMIT_LIST lines, joined with ; >`." When `LABEL_WILL_QUEUE=yes`, add "Approving also adds the `Trigger: getsentry tests` label, which runs getsentry CI on this code." Then "Comment to post:" | `Approve, no comment`, `Approve with LGTM` (I type my own comment through "Other") |
| `ASK_MERGE=yes` | `Merge` | "Merge after approving?" | `MERGE_OPTIONS` in order, first one marked "(Recommended)": `merge-now` → "Merge now", `automerge` → "Enable automerge", `not-now` → "Not now" |

If `ASK_COMMENT=no`, say "Already approved by you" above the question.

## Step 3: Apply in one call

```bash
"${CLAUDE_SKILL_DIR}/scripts/apply.sh" <PR_URL> --merge <now|auto|none> --expected-head <first 8 of HEAD_SHA> --body-file - <<'BODY'
<my comment, verbatim>
BODY
```

- The comment is exactly what I wrote: no fixes, additions, or signature. For
  `Approve, no comment`, or when `ASK_COMMENT=no`, leave out `--body-file` and the
  heredoc. `Approve with LGTM` posts `LGTM`. If my "Other" text declines the
  approval instead of giving a comment, stop without running `apply.sh`.
- `--merge`: `now` for Merge now, `auto` for Enable automerge, `none` for Not now
  or when the merge was not asked. If my typed comment is anything other than a
  plain approval (a condition, a hold, a reservation, or unclear), use `none`
  whatever I picked for the merge.
- `--expected-head`: the head shown in the question. If the PR moved since,
  `apply.sh` stops; show its error, do nothing else.
- Run it as one command on its own: the body as an inline heredoc, never a file or
  variable; no env-var prefix; nothing chained before or after it.
- If `apply.sh` refuses because the PR has my commits and is not an allowlisted
  bot PR in getsentry, show that and stop: that PR needs a review by hand.

`apply.sh` re-reads the PR, approves only if I have not, marks a bot draft ready,
adds the getsentry label in sentry, then merges. If it fails before printing
`RESULT`, show the error and stop. If `RESULT=failed`, show `ERROR`; when
`AUTO_AVAILABLE=true`, ask whether to enable automerge instead, and on yes run
`apply.sh <PR_URL> --merge auto --expected-head <same sha>`.

## Output

One line per action from `apply.sh`: approval (`APPROVED`), ready (`READIED`),
label (`LABEL_ADDED`), merge (`RESULT`), then `PR_URL`.

## Scripts

| Script | Changes GitHub | Notes |
|--------|----------------|-------|
| `scripts/pr-facts.sh` | no | author class, approval, CI, threads, `NEXT`, `RECOMMEND` |
| `scripts/apply.sh` | yes | `--dry-run` prints the gh commands instead; never uses `--admin` |
| `scripts/lib.test.sh` | no | tests for the decision functions in `scripts/lib.sh` |
