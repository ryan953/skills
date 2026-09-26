---
name: close-pr
description: Close a PR that will not merge. The task ignores closed PRs, and steps back if this was its last open one. Use on my own PRs and bot PRs when asked to "close PR N", "abandon this PR", or "drop the bot PR".
allowed-tools: Bash, Read
---

# Close a PR without merging

> **Stub.** The state change, guards and database writes are settled; the steps
> marked TODO still need to be written. The rules live in the plugin's `model/`
> folder (`../../model/` from this file): `machine.js`, `pr-machine.js` and
> `schema.sql`. If this file and those disagree, those win.

## State change

| Machine | Event | From → To | Actor |
|---------|-------|-----------|-------|
| PR | `CLOSED` | any open status → `closed` (final) | me |
| task | `PR_CLOSED` | `in_review` unchanged if other PRs are open; else → `in_progress` (another merged) or `todo` (it was the only PR), in the same transaction | pr |

**PR kinds:** `mine` and `bot`. Other people's PRs are closed by their author.

## Preconditions

Refuse, and say which one failed, unless:

- the PR is open and its kind is `mine` or `bot`

## Steps

1. TODO: confirm with the human; closing is final here.
2. TODO: close upstream, with a short reason comment.
3. Record `closed_at` and, in the same transaction, step the task back if no PRs are left open.

## Database writes

In one transaction:

```sql
UPDATE prs SET closed_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = :pr_id;
INSERT INTO events (pr_id, task_id, event, actor, from_status, to_status)
VALUES (:pr_id, :task_id, 'CLOSED', 'me', :before, 'closed');
-- Step the task back if this was its last open PR (PR_CLOSED on the task):
UPDATE tasks SET status = CASE WHEN s.merged_prs > 0 THEN 'in_progress' ELSE 'todo' END
FROM task_state s
WHERE tasks.id = :task_id AND s.id = :task_id AND s.status = 'in_review' AND s.open_prs = 0;
-- Log PR_CLOSED on the task with its old and new status.
```

## After

- Append the `events` row above; it is the audit trail.
- Run `settle`: this can make a task, and then its parent, ready for done.
