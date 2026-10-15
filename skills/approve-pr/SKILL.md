---
name: approve-pr
description: 'Approve a GitHub PR with gh, using a comment I write. For bot-authored PRs, also mark it ready, add the "Trigger: getsentry tests" label in getsentry/sentry, then ask whether to merge, enable automerge, or wait, showing CI state and unresolved review threads. Use when asked to "approve this PR", "approve #N", "approve <PR URL>", "LGTM this PR", "approve and merge", or "stamp this PR". Not for reviewing the code itself; use local-pr-review or deep-pr-review for that.'
allowed-tools: Bash, AskUserQuestion
---

# Approve PR

The scripts make every decision. Your job is to ask me the two questions, pass my
comment through unchanged, and show what the scripts print. Do not re-derive
their decisions or override them.

Run from inside the repo checkout, or pass `--repo owner/name`. `<pr>` is a number
or URL; leave it out to use the current branch's PR. Each script prints eval-safe
`KEY='value'` lines. If a script exits non-zero, show its error and stop.

## Step 1: Facts

```bash
eval "$(scripts/pr-facts.sh <pr> [--repo owner/name])"
```

Show one line: `#<PR_NUMBER> <PR_TITLE> (<AUTHOR>, <AUTHOR_CLASS>)`. Then follow `NEXT`:

| `NEXT` | Do |
|--------|----|
| `stop` | Show `STOP_REASON` and stop. |
| `done` | Show `STOP_REASON` and stop. |
| `skip-comment` | Say "Already approved by you". Go to step 3 with no body. |
| `ask-comment` | Go to step 2. |

## Step 2: Ask for the comment

Use AskUserQuestion with the options `No comment` and `LGTM`. I type my own
comment through "Other". Keep the text exactly as I wrote it: do not fix it,
expand it, or add a signature.

## Step 3: Approve, and the bot follow-through

```bash
scripts/approve.sh <pr> [--repo owner/name] --body-file - <<'BODY'
<my comment, verbatim>
BODY
```

For `No comment` or `skip-comment`, run it without `--body-file`. The script
approves only when I have not approved yet, and for bot PRs it marks a draft
ready and adds the getsentry label in sentry. It prints `APPROVED`, `READIED`,
`LABEL_ADDED`, `NEXT`, and for bot PRs `RECOMMEND`, `MERGE_OPTIONS`, `SUMMARY`.

| `NEXT` | Do |
|--------|----|
| `done` | Go to Output. |
| `automerge-on` | Show `SUMMARY`, say automerge is already on, go to Output. |
| `ask-merge` | Go to step 4. |

## Step 4: Ask about the merge

In one message, show `SUMMARY` exactly as printed, then use AskUserQuestion. The
options are `MERGE_OPTIONS` in the given order; mark the first one
"(Recommended)". Labels: `merge-now` → "Merge now", `automerge` → "Enable
automerge", `not-now` → "Not now".

## Step 5: Merge

| Choice | Run |
|--------|-----|
| merge-now | `scripts/merge.sh <pr> [--repo owner/name] --mode now` |
| automerge | `scripts/merge.sh <pr> [--repo owner/name] --mode auto` |
| not-now | nothing |

`merge.sh` prints `RESULT` (`merged`, `auto-enabled`, `auto-already`, or
`failed`). On `failed`, show `ERROR`. If `AUTO_AVAILABLE=true`, ask whether to
enable automerge instead, and run `--mode auto` only if I say yes.

## Output

End with one line per action from the script output: approval (`APPROVED`),
ready (`READIED`), label (`LABEL_ADDED`), merge (`RESULT`, or "left open"), and
`PR_URL`.

## Scripts

| Script | Changes GitHub | Notes |
|--------|----------------|-------|
| `scripts/pr-facts.sh` | no | author class, approval, CI, threads, `NEXT`, `RECOMMEND` |
| `scripts/approve.sh` | yes | `--dry-run` prints the gh commands instead |
| `scripts/merge.sh` | yes | `--dry-run` prints the gh command instead; never uses `--admin` |
| `scripts/lib.test.sh` | no | tests for the decision functions in `scripts/lib.sh` |
