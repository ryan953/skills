---
name: start-task
description: Move a todo task to in progress after reading it. Use when asked to "start task N", "pick up X", "work on the next task", or "what should I start".
allowed-tools: Bash, Read
---

# Read and start a task

> **Stub.** The state change, guards and database writes are settled; the steps
> marked TODO still need to be written. The rules live in the plugin's `model/`
> folder (`../../model/` from this file): `machine.js`, `pr-machine.js` and
> `schema.sql`. If this file and those disagree, those win.

## State change

| Machine | Event | From → To | Actor |
|---------|-------|-----------|-------|
| task | `START` | `todo` → `in_progress` | human |

## Preconditions

Refuse, and say which one failed, unless:

- the task exists and its status is `todo`
- a parent with open subtasks may still be started; say so if it has any

## Steps

1. TODO: load the task, its subtasks and its parent (`task_state`).
2. TODO: summarise the task back so the human has read it; ask to confirm if the request was vague.
3. Update the status and log `START`.

## Database writes

In one transaction:

```sql
UPDATE tasks SET status = 'in_progress' WHERE id = :task_id AND status = 'todo';
-- 0 rows changed means it was not todo: refuse.
INSERT INTO events (task_id, event, actor, from_status, to_status)
VALUES (:task_id, 'START', 'human', 'todo', 'in_progress');
```

## After

- Append the `events` row above; it is the audit trail.
