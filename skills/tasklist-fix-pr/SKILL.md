---
name: tasklist-fix-pr
description: Self-review a PR's code and push commits that fix what is wrong, including failing CI. Use on my own PRs and bot PRs when asked to "fix CI on PR N", "self-review this PR", "clean up the bot PR", or when a PR is in ci_failed.
allowed-tools: Bash, Read
---

# Self-review and push fixes

> **Stub.** The state change, guards and database writes are settled; the steps
> marked TODO still need to be written. The rules live in `models/task-list/machine.js`,
> `models/task-list/pr-machine.js` and `models/task-list/schema.sql`. If this file and those
> disagree, those win.

## State change

| Machine | Event | From → To | Actor |
|---------|-------|-----------|-------|
| PR | `NEW_COMMITS` | `ci_failed` → first match of `has_feedback`, `accepted`, `awaiting_review`; others unchanged | me |

**PR kinds:** `mine` and `bot`. On other people's PRs the author pushes; use `tasklist-review-pr` instead. This is the fix for `ci_failed`.

## Preconditions

Refuse, and say which one failed, unless:

- the PR is open (not merged or closed)
- its kind is `mine` or `bot`

## Steps

1. TODO: check out the PR branch.
2. TODO: self-review the diff; if CI failed, read the failing job first.
3. TODO: make the fixes, run the checks locally, and push.
4. Record the new head SHA; CI goes back to pending. `tasklist-detect-prs` records the new result.

## Database writes

In one transaction:

```sql
UPDATE prs SET head_sha = :new_sha, ci = 'pending' WHERE id = :pr_id;
INSERT INTO events (pr_id, task_id, event, actor, from_status, to_status, detail)
VALUES (:pr_id, :task_id, 'NEW_COMMITS', 'me', :before, :after, json_object('sha', :new_sha));
```

## After

- Append the `events` row above; it is the audit trail.
- Pushing does not clear acceptance in this model. Revisit if new commits should dismiss approvals.
