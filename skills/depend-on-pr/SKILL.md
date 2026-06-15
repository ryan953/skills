---
name: depend-on-pr
description: Track and monitor a PR dependency through its lifecycle. Creates a dex task, periodically checks CI status and review comments, notifies when ready to merge, and tracks terminal states. Will NOT merge PRs. Use when a coordination agent detects a new PR that needs monitoring, or to check on a tracked PR.
---

# depend_on_pr

Monitor a pull request from open to merged/closed. Creates a dex task to track it, checks CI and review status, surfaces comments needing attention, and notifies when the PR is ready for manual merge.

## Inputs

Accepts either:
- A PR URL: `https://github.com/owner/repo/pull/123`
- Repo + number: `owner/repo#123`
- A dex task ID for an already-tracked PR (to resume monitoring)

## Step 1 — Resolve the PR

Parse the input to extract `owner`, `repo`, and `pr_number`. If a dex task ID was given, read the task description to extract the PR URL.

Fetch PR metadata:

```bash
gh pr view <pr_number> --repo <owner>/<repo> \
  --json number,title,state,url,author,createdAt,mergedAt,closedAt,mergeable,reviewDecision,statusCheckRollup
```

If the PR doesn't exist or isn't accessible, report the error and stop.

## Step 2 — Find or create the dex task

Search for an existing tracking task:

```bash
dex list --query "<owner>/<repo>#<pr_number>" --json
```

If no task exists, create one:

```bash
dex create "Track PR: <owner>/<repo>#<pr_number> — <title>" \
  --description "Monitoring PR until merged or closed.

URL: <url>
Author: <author login>
Created: <createdAt>

Last checked: <now>
CI: <pending|passing|failing>
Review: <pending|approved|changes_requested>
State: OPEN"
```

Save the task ID.

## Step 3 — Check CI status

Extract the `statusCheckRollup` from the PR metadata. Categorize:

| Rollup | Status |
|--------|--------|
| All conclusions `SUCCESS` or `NEUTRAL` or `SKIPPED` | **passing** |
| Any conclusion `FAILURE` or `CANCELLED` or `TIMED_OUT` | **failing** — list which checks failed |
| Any status `IN_PROGRESS` or `QUEUED` or `PENDING` | **pending** |
| Empty rollup | **no checks** |

## Step 4 — Check review status

Use the `reviewDecision` field:

| Value | Meaning |
|-------|---------|
| `APPROVED` | At least one approving review, no outstanding change requests |
| `CHANGES_REQUESTED` | A reviewer requested changes |
| `REVIEW_REQUIRED` | No reviews yet or reviews are stale |
| _(empty)_ | No review requirement configured |

When `CHANGES_REQUESTED`, fetch review comments to summarize what's being asked:

```bash
gh api repos/<owner>/<repo>/pulls/<pr_number>/reviews --jq '.[] | select(.state == "CHANGES_REQUESTED") | {user: .user.login, body: .body}'
```

## Step 5 — Act on state

| PR State | CI | Review | Action |
|----------|----|--------|--------|
| `MERGED` | — | — | Go to Step 6a |
| `CLOSED` | — | — | Go to Step 6b |
| `OPEN` | failing | — | Report failing checks. Update dex task description with current status. |
| `OPEN` | passing | `APPROVED` | **Ready to merge.** Go to Step 6c. |
| `OPEN` | passing | `CHANGES_REQUESTED` | Report: CI passes but changes were requested. Summarize what reviewers asked for. |
| `OPEN` | passing | other | Report: CI passes, awaiting review approval. |
| `OPEN` | pending | — | Report: CI still running. |
| `OPEN` | no checks | `APPROVED` | **Ready to merge.** Go to Step 6c. |

Always update the dex task description with the latest status:

```bash
dex edit <task_id> --description "Monitoring PR until merged or closed.

URL: <url>
Author: <author login>
Created: <createdAt>

Last checked: <now>
CI: <status>
Review: <review status>
State: <state>"
```

## Step 6a — PR merged

```bash
dex complete <task_id> --result "PR merged: <url> at <mergedAt>" --no-commit
```

Output:
```
PR merged: <title>
<url>
Merged at: <mergedAt>
```

Stop monitoring.

## Step 6b — PR closed without merge

```bash
dex complete <task_id> --result "PR closed without merge: <url> at <closedAt>" --no-commit
```

Output:
```
PR closed without merging: <title>
<url>
Closed at: <closedAt>
```

Stop monitoring.

## Step 6c — Ready to merge

Output clearly so the user sees it:

```
PR ready to merge: <title>
<url>

CI: all checks passing
Review: approved

To merge: gh pr merge <pr_number> --repo <owner>/<repo> --squash
```

**Do NOT run the merge command.** Only display it.

Update the dex task description to reflect ready-to-merge status but do not complete it — the task stays open until actually merged.

## Rules

- **Never merge a PR.** Only display the merge command.
- **Never push commits** to the PR branch.
- **Never approve or dismiss reviews.**
- **Never comment on the PR.**
- Keep the dex task description updated with latest status on every check.
- If the repo or PR returns a 404 or permission error, report it and stop.
- When re-checking an already-tracked PR, always re-fetch fresh data from GitHub — do not rely on the dex task description for current state.
