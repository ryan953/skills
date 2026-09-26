---
name: enter-task
description: Add a new task to the task list, in todo. Use when asked to "add a task", "track this", "put X on my list", or "new todo".
allowed-tools: Bash, Read
---

# Enter a task

> **Stub.** The state change, guards and database writes are settled; the steps
> marked TODO still need to be written. The rules live in the plugin's `model/`
> folder (`../../model/` from this file): `machine.js`, `pr-machine.js` and
> `schema.sql`. If this file and those disagree, those win.

## State change

| Machine | Event | From → To | Actor |
|---------|-------|-----------|-------|
| task | `ENTER` | ∅ → `todo` | human |

## Preconditions

Refuse, and say which one failed, unless:

- the title is not empty

## Steps

1. TODO: take the title from the request; ask only if there is none.
2. TODO: check for an open task with the same title and ask before adding a duplicate.
3. Insert the task and log `ENTER`.
4. Reply with the task id and title.

## Database writes

In one transaction:

```sql
INSERT INTO tasks (title) VALUES (:title);            -- starts in todo (trigger-enforced)
INSERT INTO events (task_id, event, actor, from_status, to_status)
VALUES (last_insert_rowid(), 'ENTER', 'human', NULL, 'todo');
```

## After

- Append the `events` row above; it is the audit trail.
