---
name: tasklist-create-pr
description: Open one of my own PRs from a task I am working on and link it. Moves the task to in review, or adds another PR if it is already there. Use when asked to "open a PR for task N", "ship this task", or "create the PR".
allowed-tools: Bash, Read
---

# Create a PR for a task

> **Stub.** The state change, guards and database writes are settled; the steps
> marked TODO still need to be written. The rules live in `models/task-list/machine.js`,
> `models/task-list/pr-machine.js` and `models/task-list/schema.sql`. If this file and those
> disagree, those win.

## State change

| Machine | Event | From → To | Actor |
|---------|-------|-----------|-------|
| task | `PR_CREATED` | `in_progress` → `in_review`, or `in_review` unchanged | pr |
| PR | `(new)` | ∅ → `awaiting_review` | me |

**PR kinds:** `mine` only, origin `task`. Bot and other people's PRs are never created here; `tasklist-detect-prs` finds them.

## Preconditions

Refuse, and say which one failed, unless:

- the task is `in_progress` or `in_review`
- the branch has commits to open a PR from

## Steps

1. TODO: find or create the branch for the task and push it.
2. TODO: open the PR upstream (GitHub MCP), with the task title and a link back to the task.
3. Insert the PR row with the upstream repo and number, link it to the task, and move the task to `in_review` if it was `in_progress`.
4. Log `PR_CREATED` on the task.

## Database writes

In one transaction:

```sql
INSERT INTO prs (repo, number, url, title, kind, origin, task_id, head_sha)
VALUES (:repo, :number, :url, :title, 'mine', 'task', :task_id, :head_sha);
UPDATE tasks SET status = 'in_review' WHERE id = :task_id AND status = 'in_progress';
INSERT INTO events (task_id, pr_id, event, actor, from_status, to_status)
VALUES (:task_id, :pr_id, 'PR_CREATED', 'pr', :old_status, 'in_review');
```

## After

- Append the `events` row above; it is the audit trail.
- CI starts pending; `tasklist-detect-prs` records its result.
