---
name: accept-pr
description: Approve a PR. Use on bot PRs I have self-reviewed, and on other people's PRs once their comments are answered. Use when asked to "approve PR N", "accept this", or "LGTM".
allowed-tools: Bash, Read
---

# Accept a PR

> **Stub.** The state change, guards and database writes are settled; the steps
> marked TODO still need to be written. The rules live in the plugin's `model/`
> folder (`../../model/` from this file): `machine.js`, `pr-machine.js` and
> `schema.sql`. If this file and those disagree, those win.

## State change

| Machine | Event | From → To | Actor |
|---------|-------|-----------|-------|
| PR | `ACCEPTED` | `awaiting_review` → `accepted`; `ci_failed` and `has_feedback` unchanged until cleared | me |

**PR kinds:** `bot` and `other`. My own PRs are accepted by a reviewer, which arrives through `detect-prs`.

## Preconditions

Refuse, and say which one failed, unless:

- the PR is open, its kind is `bot` or `other`, and it is not already accepted

## Steps

1. TODO: confirm the review is finished (for `bot`, after `fix-pr` if anything needed fixing).
2. TODO: submit the approval upstream.
3. Record it.

## Database writes

In one transaction:

```sql
UPDATE prs SET accepted = 1 WHERE id = :pr_id AND accepted = 0;
INSERT INTO events (pr_id, task_id, event, actor, from_status, to_status)
VALUES (:pr_id, :task_id, 'ACCEPTED', 'me', :before, :after);
```

## After

- Append the `events` row above; it is the audit trail.
- Accepted still yields to CI failed and has feedback: if either is true, the status shows that instead.
