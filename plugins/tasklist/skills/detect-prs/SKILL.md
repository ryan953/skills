---
name: detect-prs
description: Pull PR state from the external system: insert newly found PRs (bot PRs, other people's PRs, and my PRs that did not start from a task) and record what other people, bots and CI did since the last sync. Use when asked to "sync my PRs", "check for new PRs", "what changed on my PRs", or on a schedule.
allowed-tools: Bash, Read
---

# Detect and sync PRs

> **Stub.** The state change, guards and database writes are settled; the steps
> marked TODO still need to be written. The rules live in the plugin's `model/`
> folder (`../../model/` from this file): `machine.js`, `pr-machine.js` and
> `schema.sql`. If this file and those disagree, those win.

## State change

| Machine | Event | From → To | Actor |
|---------|-------|-----------|-------|
| PR | `DETECTED` | ∅ → `awaiting_review` | system |
| PR | `CI_PASSED / CI_FAILED` | derived, only while CI is pending | ci |
| PR | `NEW_COMMITS` | derived (CI back to pending); by the author or bot | author / bot |
| PR | `COMMENT_ADDED / COMMENT_REPLIED` | derived | reviewer / author / bot |
| PR | `ACCEPTED / MERGED / CLOSED` | derived; merged and closed are final | reviewer / author |

**PR kinds:** all three. New bot and other PRs arrive with origin `detected` and no task.

## Preconditions

Refuse, and say which one failed, unless:

- the upstream system is reachable; otherwise stop without writing anything

## Steps

1. TODO: list PRs from the external system: mine, review requests, bot PRs in watched repos.
2. Upsert each on `(repo, number)`; a new row starts fresh (`awaiting_review`) and logs `DETECTED`.
3. For existing rows, diff upstream against stored facts and apply changes as events, in this order: new head SHA (CI back to pending), CI result, comment threads, acceptance, merged or closed.
4. When a PR is found closed, step its task back in the same transaction, exactly as `close-pr` does.
5. Skip events the schema refuses and report them. They mean the upstream moved in a way the model does not cover.
6. TODO: attach a detected PR of mine to a task when its branch matches one. Not modelled yet.

## Database writes

In one transaction:

```sql
INSERT INTO prs (repo, number, url, title, kind, author, origin, head_sha)
VALUES (:repo, :number, :url, :title, :kind, :author, 'detected', :head_sha)
ON CONFLICT (repo, number) DO UPDATE SET title = excluded.title, url = excluded.url;
-- New commits:     UPDATE prs SET head_sha = :sha, ci = 'pending' WHERE id = :pr_id;
-- CI result:       UPDATE prs SET ci = :result WHERE id = :pr_id AND ci = 'pending';
-- New thread:      INSERT INTO pr_comments (pr_id, external_id, author) VALUES (...) ON CONFLICT DO NOTHING;
-- Thread resolved: UPDATE pr_comments SET resolved_at = :at WHERE pr_id = :pr_id AND external_id = :thread;
-- Accepted:        UPDATE prs SET accepted = 1 WHERE id = :pr_id;
-- Merged / closed: UPDATE prs SET merged_at = :at WHERE id = :pr_id;  (or closed_at)
-- One events row per change, actor from pr-machine.js kinds.
```

## After

- Append the `events` row above; it is the audit trail.
- Run `settle`: this can make a task, and then its parent, ready for done.
