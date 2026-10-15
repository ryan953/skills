---
name: approve-pr
description: 'Approve a GitHub PR with gh, using a comment I write. For bot-authored PRs, also mark it ready, add the "Trigger: getsentry tests" label in getsentry/sentry, then ask whether to merge, enable automerge, or wait, showing CI state and unresolved review threads. Use when asked to "approve this PR", "approve #N", "approve <PR URL>", "LGTM this PR", "approve and merge", or "stamp this PR". Not for reviewing the code itself; use local-pr-review or deep-pr-review for that.'
allowed-tools: Bash, AskUserQuestion
---

# Approve PR

Approve one PR. Ask for my comment first, and post it exactly as I wrote it.
Bot PRs get extra follow-up steps; another human's PR is done after the approval.

## Step 1: Collect facts

Run from inside the repo checkout, or pass `--repo`:

```bash
eval "$(scripts/pr-facts.sh [<pr-number-or-url>] [--repo owner/name])"
```

With no argument it uses the current branch's PR. The script is read-only. It sets:

| Key | Meaning |
|-----|---------|
| `REPO`, `PR_NUMBER`, `PR_TITLE`, `PR_URL`, `PR_STATE`, `IS_DRAFT` | the PR |
| `AUTHOR`, `AUTHOR_CLASS` | `mine` \| `bot` \| `other` (another human) |
| `MY_APPROVAL` | `yes` when my latest review is a standing approval |
| `IS_SENTRY`, `TEST_LABEL`, `HAS_TEST_LABEL` | whether the getsentry label applies, and if it is already on |
| `MERGE_STATE`, `MERGE_METHOD`, `AUTO_MERGE_ALLOWED`, `AUTO_MERGE_ON` | merge options |
| `CI_STATE` | `green` \| `pending` \| `failing` \| `none` |
| `CI_PASS`, `CI_FAIL`, `CI_PENDING`, `CI_SKIPPING`, `CI_FAILING` | check counts, and the names of failed checks |
| `UNRESOLVED_THREADS`, `THREADS` | count, and one line per unresolved thread |

If the script fails, show its error and stop. Do not guess the author class.

Stop with a one-line reason when:

- `PR_STATE` is not `OPEN`.
- `AUTHOR_CLASS=mine`: GitHub does not let you approve your own PR.

If `MY_APPROVAL=yes`, say "Already approved by you", skip steps 2 and 3, and
continue at step 4. A second approval would only add a duplicate review, but a bot
PR still needs its label and merge decision. For `AUTHOR_CLASS=other` that means
there is nothing left to do.

## Step 2: Ask for the comment

Show one line: `#<PR_NUMBER> <PR_TITLE> (<AUTHOR>, <AUTHOR_CLASS>)`. Then use
AskUserQuestion with the options `No comment` and `LGTM`. I type my own comment
through "Other".

Post the text exactly as I wrote it. Do not fix it, expand it, or add a signature.

## Step 3: Approve

```bash
gh pr review "$PR_NUMBER" --repo "$REPO" --approve --body-file - <<'BODY'
<my comment, verbatim>
BODY
```

For `No comment`, run `gh pr review "$PR_NUMBER" --repo "$REPO" --approve` with no body.

If `AUTHOR_CLASS=other`, report the approval and stop.

## Step 4: Bot PRs only

1. If `IS_DRAFT=true`, run `gh pr ready "$PR_NUMBER" --repo "$REPO"`. A draft
   cannot merge, and the approval is what vouches for it.
2. If `IS_SENTRY=yes` and `HAS_TEST_LABEL=no`, add the label:
   ```bash
   gh pr edit "$PR_NUMBER" --repo "$REPO" --add-label "$TEST_LABEL"
   ```
   Use the label name exactly as `TEST_LABEL` gives it. This queues new getsentry
   checks, so after it CI counts as `pending`, whatever `CI_STATE` said.
3. Write a short status in chat:
   - CI: `CI_STATE` with the pass / fail / pending / skipping counts, plus
     `CI_FAILING` when it is not empty. Never count `skipping` as passed.
   - Review threads: `UNRESOLVED_THREADS`, then the `THREADS` lines as given.
     Write "No unresolved review threads" when the count is 0.
4. If `AUTO_MERGE_ON=yes`, say automerge is already on and stop.
5. In the same message, ask with AskUserQuestion. Put the recommended option
   first, from this table:

   | Situation | Recommend |
   |-----------|-----------|
   | `UNRESOLVED_THREADS` > 0 or `CI_STATE=failing` | `Not now` |
   | label added in step 4.2, or `CI_STATE=pending` | `Enable automerge` |
   | `CI_STATE=green` and `MERGE_STATE=CLEAN` | `Merge now` |

   Show `Enable automerge` only when `AUTO_MERGE_ALLOWED=true`.

6. Do what I choose:

   | Choice | Command |
   |--------|---------|
   | Merge now | `gh pr merge "$PR_NUMBER" --repo "$REPO" --"$MERGE_METHOD"` |
   | Enable automerge | `gh pr merge "$PR_NUMBER" --repo "$REPO" --"$MERGE_METHOD" --auto` |
   | Not now | nothing |

   If `Merge now` is refused because the PR is blocked or checks are not done,
   show the gh error. Offer automerge only if `AUTO_MERGE_ALLOWED=true`.
   Do not add `--admin`.

## Output

End with one line per action that was done: approved (with or without a comment,
or already approved),
marked ready, label added, merged / automerge on / left open, and the `PR_URL`.
