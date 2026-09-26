---
name: tasklist-settle
description: Apply the task change nobody clicks: move in-review tasks to done once every linked PR is merged and every subtask is done. Cascades to parents. Run after any merge, detection sync, or task finishing.
allowed-tools: Bash, Read
---

# Settle automatic task transitions

> **Stub.** The state change, guards and database writes are settled; the steps
> marked TODO still need to be written. The rules live in `models/task-list/machine.js`,
> `models/task-list/pr-machine.js` and `models/task-list/schema.sql`. If this file and those
> disagree, those win.

## State change

| Machine | Event | From → To | Actor |
|---------|-------|-----------|-------|
| task | `AUTO_DONE` | `in_review` → `done` | auto |

## Preconditions

Refuse, and say which one failed, unless:

- nothing to check up front; `tasks_to_auto_complete` only lists tasks that are ready
- step-backs from closed PRs are not done here. They happen in the same transaction as the close (`tasklist-close-pr`, `tasklist-detect-prs`), before this runs. Otherwise a task whose last open PR closed would look ready and skip to done.

## Steps

1. Move every task in `tasks_to_auto_complete` to done, logging `AUTO_DONE`.
2. Repeat until a pass changes nothing: a child finishing can make its in-review parent ready.
3. TODO: report what moved. A parent in progress with every subtask done is not moved; suggest `tasklist-mark-done`.

## Database writes

In one transaction:

```sql
-- Repeat until no rows change:
INSERT INTO events (task_id, event, actor, from_status, to_status)
SELECT id, 'AUTO_DONE', 'auto', 'in_review', 'done' FROM tasks_to_auto_complete;
UPDATE tasks SET status = 'done' WHERE id IN (SELECT id FROM tasks_to_auto_complete);
```

## After

- Append the `events` row above; it is the audit trail.
