---
name: tasklist-decompose-task
description: Split a task into smaller subtasks. The task keeps its status and becomes a parent; each subtask starts in todo. Use when asked to "break this down", "decompose task N", "split into subtasks", or "this is too big".
allowed-tools: Bash, Read
---

# Decompose a task into subtasks

> **Stub.** The state change, guards and database writes are settled; the steps
> marked TODO still need to be written. The rules live in `models/task-list/machine.js`,
> `models/task-list/pr-machine.js` and `models/task-list/schema.sql`. If this file and those
> disagree, those win.

## State change

| Machine | Event | From → To | Actor |
|---------|-------|-----------|-------|
| task | `DECOMPOSE` | unchanged (`todo`, `in_progress` or `in_review`) | human |
| task | `ENTER` | ∅ → `todo`, once per new subtask | human |

## Preconditions

Refuse, and say which one failed, unless:

- the task exists and is not `done`
- at least one new subtask

## Steps

1. TODO: read the task and propose subtasks; let the human edit the list before writing.
2. Insert each subtask with `parent_id`, log `DECOMPOSE` on the parent and `ENTER` on each child.
3. Do not change the parent's status.
4. Reply with the new subtask ids.

## Database writes

In one transaction:

```sql
-- Repeat per subtask:
INSERT INTO tasks (title, parent_id) VALUES (:subtask_title, :task_id);
INSERT INTO events (task_id, event, actor, from_status, to_status, detail)
VALUES (last_insert_rowid(), 'ENTER', 'human', NULL, 'todo', json_object('parent', :task_id));
-- Once, on the parent (status unchanged):
INSERT INTO events (task_id, event, actor, from_status, to_status, detail)
VALUES (:task_id, 'DECOMPOSE', 'human', :status, :status, json_object('subtasks', :count));
```

## After

- Append the `events` row above; it is the audit trail.
- The parent can no longer be done until every subtask is done.
