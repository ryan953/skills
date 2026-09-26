---
name: merge-pr
description: Merge an accepted PR, then let its task finish if this was the last open PR. Use on my own PRs and bot PRs when asked to "merge PR N", "ship it", or when a PR is accepted.
allowed-tools: Bash, Read
---

# Merge a PR

> **Stub.** The state change, guards and database writes are settled; the steps
> marked TODO still need to be written. The rules live in the plugin's `model/`
> folder (`../../model/` from this file): `machine.js`, `pr-machine.js` and
> `schema.sql`. If this file and those disagree, those win.

## State change

| Machine | Event | From → To | Actor |
|---------|-------|-----------|-------|
| PR | `MERGED` | `accepted` → `merged` (final) | me |
| task | `AUTO_DONE` | `in_review` → `done`, via `settle` | auto |

**PR kinds:** `mine` and `bot`. Other people's PRs are merged by their author.

## Preconditions

Refuse, and say which one failed, unless:

- the PR's status is `accepted`: CI not failing, no unresolved comments, accepted (trigger-enforced)
- its kind is `mine` or `bot`

## Steps

1. TODO: merge upstream with the repo's merge method.
2. Record `merged_at`.

## Database writes

In one transaction:

```sql
UPDATE prs SET merged_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = :pr_id;
INSERT INTO events (pr_id, task_id, event, actor, from_status, to_status)
VALUES (:pr_id, :task_id, 'MERGED', 'me', 'accepted', 'merged');
```

## After

- Append the `events` row above; it is the audit trail.
- Run `settle`: this can make a task, and then its parent, ready for done.
