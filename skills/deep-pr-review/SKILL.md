---
name: deep-pr-review
description: Deeply review a pull request from multiple angles — verify it against the source issue, spawn subagents for independent perspectives, compare alternative approaches, and PROVE findings by writing tests and running them. Use when asked to "review this PR", "review PR #N", "look at this PR and review it", "is this fix appropriate", "review it from different angles", "compare approaches", or to scrutinize a Seer/autofix/bot-generated PR. Goes beyond a read-through: it exercises the code, and can land corrected fixes once the review surfaces them. For a style/convention pass use frontend-conventions; for your own uncommitted diff use code-review; for CI-failure/feedback loops use iterate-pr.
allowed-tools: Bash, Read, Edit, Write, Agent, Skill, Monitor, SendMessage, Grep, Glob, EnterWorktree
---

# Deep PR Review

Review a PR the way a skeptical senior engineer would: don't trust the description,
**go back to the source of truth** (the issue it claims to fix), look at it from
angles a single read misses, and **prove every finding by running code** — a test that
fails on the PR and passes on your fix is worth more than any amount of prose.

This is for reviews that matter: bot/Seer/autofix-generated PRs, subtle refactors,
anything where "looks fine" isn't good enough. For a quick style pass use
`frontend-conventions`; for your own uncommitted diff use `/code-review`.

## The core loop

1. **Gather** the PR + the issue it fixes (both sides of the diff, the linked issue/ticket).
2. **Fan out** independent subagents on orthogonal angles (correctness, alternatives, security…).
3. **Verify against the source** — does the fix actually address the real problem?
4. **Prove findings** — apply the PR locally, write probing tests, run them.
5. **Compare alternatives** — is there a simpler/idiomatic fix already in the codebase?
6. **Synthesize** — reconcile subagent claims against your own empirical results; downgrade anything you couldn't reproduce.
7. **(Optional) Land fixes** in a worktree, verify, commit, push.

## Step 1 — Gather

```bash
gh pr view <N> --json title,body,state,author,headRefName,baseRefName,additions,deletions,changedFiles,url,commits,labels
gh pr diff <N>
```

Fetch both versions of each changed file (base and head) so you can see exactly what
moved. If the PR body cites an issue ("Fixes ABC-123", a Sentry issue, a Linear ticket),
**open it** — read the original report, the stack trace, the acceptance criteria, and any
attached analysis. A fix that resolves the lint error but changes behavior is not a fix.

For Sentry issues use the `sentry` MCP (`get_sentry_resource` / `search_issues`); note when
the issue's own suggested fix (e.g. Seer's analysis) differs from what the PR shipped — that
divergence is often where the bugs live.

## Step 2 — Fan out subagents (parallel, one message)

Spawn `general-purpose` agents on **orthogonal** angles so they don't overlap. Give each a
sharp brief with explicit hypotheses to confirm/refute *with file:line evidence*, and tell
them to open real files, not theorize. Typical angles:

- **Correctness/bugs** — enumerate concrete failure scenarios (inputs → wrong output). For
  React: stale state that never resets, effect dependency identity, semantic flips on
  null/empty/edge inputs, lifecycle/remount behavior.
- **Alternatives** — enumerate ≥3 approaches incl. the PR's, compare on a table
  (correctness, reuse, LOC, convention-fit, testability, risk), rank, and show concrete
  replacement code for the top pick. **Especially: is there an existing helper/hook/util the
  PR reinvents?** (Check siblings in the same file.)
- **Security / access-control** when the surface warrants (see `sentry-security`, `django-access-review`).

Also invoke the repo's own pattern-review skills directly (don't just delegate):
`sentry-javascript-bugs`, `sentry-backend-bugs`, `find-bugs`, `code-review`.

Subagents run in the background and notify on completion — keep working; don't block-poll.
When they report, **treat their claims as hypotheses, not conclusions** (see Step 6).

## Step 3 & 4 — Verify by running code (the part people skip)

Reading tells you what the code *says*; running tells you what it *does*.

1. Apply the PR's change to a local checkout (Edit the file to match the diff, or check out
   the branch — see Step 7).
2. Run the **existing** tests — do they even cover the new behavior? (Often they don't.)
3. **Write probing tests** for each suspected regression. Make them assert the *old* correct
   behavior so they fail on the PR. Run them. `console.log` the actual values.
4. To prove a finding is real: show the test **fails against the PR code** and **passes
   against your proposed fix** (swap implementations, rerun). That's the gold standard —
   it converts "I think this is a bug" into "here is the bug."
5. Check realism before rating severity: trace the actual consumer/route/caller. A bug that
   requires a remount that never happens is *latent*, not *live* — say which.

Keep throwaway probes in `$CLAUDE_JOB_DIR/tmp` or a `*.probe.spec.*` you delete; fold the
keepers into the real test file. Run the project's lint + typecheck + any convention
detector (e.g. a lint-rule detector script) on both the PR code and your fix.

## Step 5 — Compare alternatives honestly

Don't just critique — show the better option as real code. The most common finding on
generated PRs: **it hand-rolls logic the codebase already has a utility for** (a shared hook,
a helper, a base class). Look at the immediate neighbors of the changed function; if a
sibling solves the same shape of problem, reuse beats reinvention. But verify the reused
utility actually covers all cases (a naive "just use the shared hook" may miss an edge the
PR's author was — accidentally — handling).

## Step 6 — Synthesize (reconcile, don't rubber-stamp)

You will get subagent reports that disagree with each other or with your gut. Resolve
disagreements **empirically**, not by seniority of the claim:

- If bug-hunter says HIGH but your test can't reproduce it under realistic conditions,
  downgrade to latent/LOW and say why.
- If the alternatives agent's recommended code still fails one of your regression tests,
  say so and combine the best of each (e.g. "reuse the shared hook" + "add the reset it omits").
- Rate each finding: severity, live-vs-latent, and the evidence (a failing test > a traced
  path > a pattern match).

Deliver: verdict (approve / request changes), the source-issue check, findings ranked by
severity with reproductions, the alternatives comparison, and — if you wrote one — the
corrected implementation with its passing tests.

## Step 7 — (Optional) Land the fix in a worktree

Only if asked to make edits / open or update the PR. Keep the user's main checkout clean.

```bash
gh pr checkout <N>            # or: git fetch origin <branch>
git worktree add -b <branch> .claude/worktrees/pr-<N> FETCH_HEAD   # if not using gh checkout
```

Then `EnterWorktree` into it. A worktree may need `pnpm install` (its post-checkout
`devenv sync` can time out — that's fine for frontend-only work; install deps directly if a
module is missing). Apply fixes there, following these preferences the user has repeated:

- **Fix the real defects**, not just the symptom the PR targeted.
- **Reuse existing utilities** over hand-rolled logic when it genuinely fits.
- **Trim code comments** to a few focused lines — no essay blocks explaining every branch.
- **Add regression tests** for each fixed defect (generated PRs usually ship none).

Verify before committing: lint, tests, typecheck, and the relevant convention detector all
green; a quick render-loop / no-op-setState sanity check for React hooks. Commit with a
Sentry-style conventional message (`fix(area): ...`) via the `commit` skill; amend rather
than stack when iterating on your own commit. Push only when the user says to
(`--force-with-lease` after an amend; if it rejects as stale, `git fetch` and confirm the
remote still points at your prior commit before forcing).

To iterate visually, use the `diff` skill (revdiff in a tmux window) on `HEAD~1` so the
reviewer sees just your commit; address annotations and relaunch on the same range.

## Anti-patterns

- Reviewing from the diff alone without opening the source issue.
- Reporting a bug you never reproduced. Run it or mark it explicitly as unverified.
- Accepting a subagent's severity without your own check.
- "Just use the shared hook" without confirming it handles every case the PR did.
- Verbose comment blocks; leaving throwaway probe files in the tree; pushing unasked.
