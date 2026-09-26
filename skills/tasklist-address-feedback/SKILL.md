---
name: tasklist-address-feedback
description: Answer each unresolved review comment on one of my PRs: fix it in code or reply with why not, and resolve the thread. Use when asked to "address the review", "reply to comments on PR N", or when my PR is in has_feedback.
allowed-tools: Bash, Read
---

# Address feedback on my PR

> **Stub.** The state change, guards and database writes are settled; the steps
> marked TODO still need to be written. The rules live in `models/task-list/machine.js`,
> `models/task-list/pr-machine.js` and `models/task-list/schema.sql`. If this file and those
> disagree, those win.

## State change

| Machine | Event | From → To | Actor |
|---------|-------|-----------|-------|
| PR | `COMMENT_REPLIED` | `has_feedback` → first match of `accepted`, `awaiting_review` once none are left | me |

**PR kinds:** `mine` only. On bot PRs the bot replies, and on other people's PRs the author does. This is the fix for `has_feedback`.

## Preconditions

Refuse, and say which one failed, unless:

- the PR is open and its kind is `mine`
- it has at least one unresolved comment

## Steps

1. TODO: list unresolved threads (`pr_comments` where `resolved_at IS NULL`) with their upstream text.
2. TODO: for each, change the code or draft a reply; confirm replies with the human before posting.
3. If code changed, push, and record it as `NEW_COMMITS` too (see `tasklist-fix-pr`).
4. Post each reply, resolve the thread upstream, and record it.

## Database writes

In one transaction:

```sql
UPDATE pr_comments SET resolved_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
WHERE pr_id = :pr_id AND external_id = :thread_id AND resolved_at IS NULL;
INSERT INTO events (pr_id, task_id, event, actor, from_status, to_status, detail)
VALUES (:pr_id, :task_id, 'COMMENT_REPLIED', 'me', :before, :after, json_object('thread', :thread_id));
```

## After

- Append the `events` row above; it is the audit trail.
