---
name: tasklist-review-pr
description: Review a PR written by someone else and leave comments: read the diff, optionally pull the code and self-review it, then turn the notes into review comments. Use when asked to "review PR N", "look at Sam's PR", or for a review request.
allowed-tools: Bash, Read
---

# Review someone else's PR

> **Stub.** The state change, guards and database writes are settled; the steps
> marked TODO still need to be written. The rules live in `models/task-list/machine.js`,
> `models/task-list/pr-machine.js` and `models/task-list/schema.sql`. If this file and those
> disagree, those win.

## State change

| Machine | Event | From → To | Actor |
|---------|-------|-----------|-------|
| PR | `COMMENT_ADDED` | `awaiting_review` or `accepted` → `has_feedback`; `ci_failed` unchanged | me |

**PR kinds:** `other` only. On my PRs and bot PRs, comments come from reviewers and arrive through `tasklist-detect-prs`.

## Preconditions

Refuse, and say which one failed, unless:

- the PR is open and its kind is `other`

## Steps

1. TODO: read the PR description and diff.
2. TODO: if needed, pull the branch locally and self-review or run it.
3. TODO: turn review notes into comments; show them to the human before posting.
4. Post the comments and record one thread per comment.
5. If there is nothing to say, use `tasklist-accept-pr` instead.

## Database writes

In one transaction:

```sql
INSERT INTO pr_comments (pr_id, external_id, author) VALUES (:pr_id, :thread_id, 'me');
INSERT INTO events (pr_id, event, actor, from_status, to_status, detail)
VALUES (:pr_id, 'COMMENT_ADDED', 'me', :before, :after, json_object('thread', :thread_id));
```

## After

- Append the `events` row above; it is the audit trail.
- The author replies, pushes and merges. Those arrive through `tasklist-detect-prs`.
