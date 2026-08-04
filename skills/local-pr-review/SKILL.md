---
name: local-pr-review
description: Review a GitHub pull request locally (checked out on disk), then ask the reviewer for a verdict — approved, rejected, or neither — and post it to GitHub. If the verdict is approved and the PR was authored by a bot, mark it Ready for Review and apply the "Trigger: getsentry tests" label. Use when asked to "review this PR locally", "check out and review PR #N", "review <github PR URL>", or to review a Seer/autofix/bot-authored PR end-to-end including the ready-for-review + trigger-label step.
allowed-tools: Bash, Read, Grep, Glob, Agent, Skill, EnterWorktree, AskUserQuestion
---

# Local PR review

Check out a PR locally, review it at a depth matched to its size, ask the
reviewer for a verdict, then act on GitHub: post the verdict as a real review,
and — only on approval of a bot-authored PR — flip it out of draft and label
it to trigger getsentry tests.

This composes existing review skills rather than re-implementing review logic:
it decides *how much* review to run and *what to do with the verdict*.

## Step 1: Gather PR metadata

```bash
gh pr view <url-or-number> --json number,title,url,author,isDraft,state,baseRefName,headRefName,additions,deletions,changedFiles,labels,body [--repo owner/repo]
```

Note especially:
- `author.is_bot` — determines whether the ready-for-review/label step applies later.
- `isDraft` — bot-authored Seer/autofix PRs are typically opened as drafts.
- `additions` + `deletions` + `changedFiles` — drives the depth decision in Step 3.
- `state` — if already `MERGED` or `CLOSED`, tell the reviewer and stop; there's nothing to review.

## Step 2: Check the PR out locally

Prefer a worktree so this never disturbs other in-progress work in the repo checkout:

```bash
cd <repo-checkout>            # e.g. ~/code/sentry
git fetch origin <headRefName>
git worktree add -b pr-<number>-review .claude/worktrees/pr-<number>-review FETCH_HEAD
```

Then `EnterWorktree` with `path` set to that directory. If a worktree can't be created
(e.g. not a git repo the harness manages), fall back to `gh pr checkout <number>` directly
in the existing checkout — but say so, since it mutates the reviewer's working branch.

## Step 3: Decide review depth from PR size

Don't default to maximum thoroughness — see [[feedback_scale_pr_review_depth]]. Use
`changedFiles`/`additions`+`deletions` from Step 1, plus whether the PR body cites a
specific issue with concrete evidence (a stack trace, a linked Sentry/Linear ticket),
to pick one of:

- **Small, well-evidenced** (roughly ≤5 files, ≤~50 lines changed, and a clear
  issue/stack-trace match — this is the common case for Seer/autofix bot PRs like
  pure-render-function fixes): read the diff directly (`gh pr diff <number>`), confirm
  the fix matches the cited issue, check it compiles/lints, and run any directly
  relevant existing tests. Skip full multi-angle fan-out.
- **Larger or architecturally risky** (many files, new abstractions, auth/payments/
  migrations touched, or no clear single-issue match): invoke the `deep-pr-review`
  skill for the full multi-angle treatment (correctness, alternatives, CI status,
  proof-by-test).
- **Frontend-only PRs** at either depth: also run `frontend-conventions` on the diff
  (see html-review/deep-pr-review skills for how) — a bot fix that "adheres to
  pure-render-functions" convention is exactly the kind of PR that convention drift
  hides in.

When unsure which bucket a PR falls into, err toward the lighter pass and say
explicitly what was and wasn't checked — the reviewer can ask for the deeper pass.

## Step 4: Ask for a verdict

Once the review is complete, use `AskUserQuestion` (not a plain text question) to ask
for exactly one of three outcomes:

- **Approved** — the PR is correct and ready to proceed.
- **Rejected** — request changes; capture what needs to change as the review body.
- **Neither** — no verdict yet (reviewer wants to think, or the PR needs more work
  from someone else before a verdict makes sense). Nothing further happens on GitHub.

Present your review findings (what you checked, what you found) before asking, so the
verdict is an informed choice rather than a blind pick.

## Step 5: Post the verdict to GitHub

- **Approved**:
  ```bash
  gh pr review <number> --approve --body "<summary of what was reviewed>" [--repo owner/repo]
  ```
- **Rejected**:
  ```bash
  gh pr review <number> --request-changes --body "<specific changes needed>" [--repo owner/repo]
  ```
- **Neither**: post nothing. Report the review findings and stop — leave the verdict
  step for later.

## Step 6: Bot-authored PR — only on approval

If (and only if) the verdict was **Approved** *and* `author.is_bot` was `true` in Step 1:

```bash
gh pr ready <number> [--repo owner/repo]
gh pr edit <number> --add-label "Trigger: getsentry tests" [--repo owner/repo]
```

Skip this step entirely on Rejected or Neither, and skip it for human-authored PRs
regardless of verdict — the label triggers CI spend and Ready-for-Review visibly
changes review-queue state for others, so it's gated strictly on "a human approved
this" ([[feedback_draft_prs]] discusses the same instinct in the other direction —
default to caution around shared-state changes).

## Step 7: Clean up

If a worktree was created in Step 2 and no further edits are expected there, use
`ExitWorktree` with `action: "remove"` once the reviewer confirms they're done —
don't remove it while the reviewer might still want to poke at the checkout.

## Notes

- This skill never edits the PR's code. If review findings suggest a fix, offer to
  hand off to `deep-pr-review`'s Step 7 (land-the-fix-in-a-worktree) or `iterate-pr`
  as a separate, explicit follow-up — don't silently start editing.
- `gh pr view --json author` returns `author.is_bot` directly; no need to guess from
  the username (though Seer/autofix bots on sentry conventionally use branch prefixes
  like `seer/fix/...`).
- If `gh pr ready` reports the PR is already ready (not a draft), that's a no-op, not
  an error — just don't run it for PRs that were never drafts.
