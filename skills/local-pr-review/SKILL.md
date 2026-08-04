---
name: local-pr-review
description: Review a GitHub pull request locally end-to-end — check it out, run existing review skills scaled to its size, open it in revdiff for inline annotation, route those annotations by author (apply-and-push for bot-authored PRs, post as GitHub review comments for human-authored PRs), then ask the reviewer for a verdict (approved/rejected/neither) and post it to GitHub. If the verdict is approved and the PR was authored by a bot, mark it Ready for Review and apply the "Trigger: getsentry tests" label. Use when asked to "review this PR locally", "check out and review PR #N", "review <github PR URL>", or to review a Seer/autofix/bot-authored PR end-to-end including the ready-for-review + trigger-label step.
allowed-tools: Bash, Read, Grep, Glob, Agent, Skill, EnterWorktree, ExitWorktree, AskUserQuestion, Monitor
---

# Local PR review

Check out a PR locally, run existing review skills at a depth matched to its
size, open it in revdiff so the reviewer can read the code and leave inline
comments, route those comments by author, then ask for a verdict and act on
GitHub.

This composes existing review skills and the `diff` (revdiff) skill rather
than re-implementing review or annotation logic: it decides *how much* review
to run, *what to do with revdiff's annotations*, and *what to do with the
verdict*.

## Step 1: Gather PR metadata

```bash
gh pr view <url-or-number> --json number,title,url,author,isDraft,state,baseRefName,headRefName,additions,deletions,changedFiles,labels,body [--repo owner/repo]
```

Note especially:
- `author.is_bot` — determines both the annotation-routing in Step 5 and the
  ready-for-review/label step in Step 7.
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

## Step 3: Run existing review skills, scaled to PR size

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
  — a bot fix that "adheres to pure-render-functions" convention is exactly the kind
  of PR that convention drift hides in.

When unsure which bucket a PR falls into, err toward the lighter pass and say
explicitly what was and wasn't checked.

**Present these findings to the reviewer before opening revdiff** — they should have
the automated review's conclusions in hand while deciding what, if anything, to
annotate directly on the code.

## Step 4: Open the PR in revdiff for inline annotation

Invoke the `diff` skill with no arguments from inside the worktree. Because the worktree
is on a feature branch checked out from the PR's head, `diff`'s inferred range (merge-base
of the trunk branch → working tree) is exactly the PR's diff — no explicit range needed.

Wait for the revdiff session to finish using the `diff` skill's `$DONE`-file Monitor
pattern (Step 2 of that skill), then read `$OUT` for annotations (Step 3 of that skill).
If `$OUT` is empty, there's nothing to route in Step 5 — proceed straight to Step 6.

## Step 5: Route annotations by author

Read each annotation (`file:line (+/-)` plus comment text, or `(file-level)`). Use the
`diff` skill's Step 4 classification first: explanation requests (`explain`/`describe`/
`what is`/`how does`/`??`) get answered in chat and are **not** routed anywhere below —
only code-change directives are.

**If `author.is_bot` is `true`:** apply the annotations as edits directly in the
worktree, the same way `deep-pr-review`'s Step 7 lands fixes:

```bash
# edit the files per each annotation
# run lint/typecheck/relevant tests
```

Commit with the `commit` skill's conventions, then push to the PR's own branch:

```bash
git push origin HEAD:<headRefName>
```

Do **not** force-push (this adds a commit on top of the bot's branch, not rewriting it).
Do **not** run the ready-for-review/label step here — that stays gated on the Step 7
verdict below, even for bot PRs whose annotations you just pushed.

**If `author.is_bot` is `false`:** do not touch the code. Instead post the annotations
as a single GitHub PR review with inline comments:

```bash
gh api --method POST repos/<owner>/<repo>/pulls/<number>/reviews --input - <<'EOF'
{
  "event": "COMMENT",
  "body": "Inline comments from local review.",
  "comments": [
    {"path": "<file>", "line": <line>, "side": "RIGHT", "body": "<comment text>"}
  ]
}
EOF
```

Use `"side": "RIGHT"` for `(+)` annotations (added/current lines) and `"side": "LEFT"`
for `(-)` annotations (removed/old lines). Any `(file-level)` annotation has no line to
attach to — fold its text into the review's top-level `body` instead of a `comments` entry.
This call is separate from — and does not by itself constitute — the approve/request-changes
verdict in Step 7; it posts as a plain `COMMENT` review.

## Step 6: Loop if edits were made

If Step 5 applied edits (bot-authored case), relaunch the `diff` skill with the same
(no-arg) invocation so the reviewer sees the new state before finalizing a verdict.
Repeat Steps 4–6 until a revdiff session ends with no new annotations.

## Step 7: Ask for a verdict

Once annotation routing has settled, use `AskUserQuestion` (not a plain text question)
to ask for exactly one of three outcomes:

- **Approved** — the PR is correct and ready to proceed.
- **Rejected** — request changes; capture what needs to change as the review body.
- **Neither** — no verdict yet. Nothing further happens on GitHub.

Summarize what was checked (Step 3's findings) and what was done with any annotations
(Step 5) before asking, so the verdict is an informed choice.

## Step 8: Post the verdict to GitHub

- **Approved**:
  ```bash
  gh pr review <number> --approve --body "<summary of what was reviewed>" [--repo owner/repo]
  ```
- **Rejected**:
  ```bash
  gh pr review <number> --request-changes --body "<specific changes needed>" [--repo owner/repo]
  ```
- **Neither**: post nothing. Report the review findings and stop.

## Step 9: Bot-authored PR — only on approval

If (and only if) the verdict was **Approved** *and* `author.is_bot` was `true` in Step 1:

```bash
gh pr ready <number> [--repo owner/repo]
gh pr edit <number> --add-label "Trigger: getsentry tests" [--repo owner/repo]
```

Skip this step entirely on Rejected or Neither, and skip it for human-authored PRs
regardless of verdict — the label triggers CI spend and Ready-for-Review visibly
changes review-queue state for others, so it's gated strictly on "a human approved
this" ([[feedback_draft_prs]] discusses the same instinct in the other direction —
default to caution around shared-state changes). This is independent of whether Step 5
already pushed a commit — pushing fixes and approving the PR are different actions.

## Step 10: Clean up

If a worktree was created in Step 2 and no further edits are expected there, use
`ExitWorktree` with `action: "remove"` once the reviewer confirms they're done —
don't remove it while the reviewer might still want to poke at the checkout.

## Notes

- This skill edits the PR's code **only** for bot-authored PRs, and only in direct
  response to revdiff annotations (Step 5) — never speculatively. For human-authored
  PRs it never edits code; findings go back as GitHub comments, not commits.
- `gh pr view --json author` returns `author.is_bot` directly; no need to guess from
  the username (though Seer/autofix bots on sentry conventionally use branch prefixes
  like `seer/fix/...`).
- If `gh pr ready` reports the PR is already ready (not a draft), that's a no-op, not
  an error — just don't run it for PRs that were never drafts.
- `gh api .../reviews` with `"event": "COMMENT"` posts comments without approving or
  requesting changes — the actual verdict always goes through Step 8's separate call.
