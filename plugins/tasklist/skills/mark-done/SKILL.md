---
name: mark-done
description: Mark an in-progress task done when it never needed a PR, such as a parent that only groups subtasks. Use when asked to "mark task N done", "close out this task", or "finish the parent".
allowed-tools: Bash, Read
---

# Mark a task done by hand

> **Stub.** The state change, guards and database writes are settled; the steps
> marked TODO still need to be written. The rules live in the plugin's `model/`
> folder (`../../model/` from this file): `machine.js`, `pr-machine.js` and
> `schema.sql`. If this file and those disagree, those win.

## State change

| Machine | Event | From → To | Actor |
|---------|-------|-----------|-------|
| task | `COMPLETE` | `in_progress` → `done` | human |

## Preconditions

Refuse, and say which one failed, unless:

- the task is `in_progress`
- `task_state.ready_for_done`: no open PRs and no incomplete subtasks (closed PRs are ignored)
- tasks in review are never marked done by hand; `settle` does that when their PRs merge

## Steps

1. TODO: show what is still open if the task is not ready, and stop.
2. Update the status and log `COMPLETE`.

## Database writes

In one transaction:

```sql
UPDATE tasks SET status = 'done' WHERE id = :task_id AND status = 'in_progress';
-- The done trigger refuses this if PRs or subtasks are still open.
INSERT INTO events (task_id, event, actor, from_status, to_status)
VALUES (:task_id, 'COMPLETE', 'human', 'in_progress', 'done');
```

## After

- Append the `events` row above; it is the audit trail.
- Run `settle`: this can make a task, and then its parent, ready for done.
