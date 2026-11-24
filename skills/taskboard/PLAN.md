# Taskboard plan

SKILL.md does not load this file. It records what is built, what is next, and the decisions behind them.

## Built (ryan953/skills#19)

1. Ledger, sync script and linker.
2. `/taskboard` manager flow: sync, report, clean-up after the user's yes.
3. `dispatch` and `assign`: reuse the owner, then a session, then jr, then a new session. Brief kinds: full cycle, review only, validate only.
4. Mod: band, pane, 10-minute sync timer.
5. Review-queue filter: team review requests that touch `TASKBOARD_WATCH` paths are tasks.
   - Also built: a conversation is asked before it is archived, and remaining work shows in the `follow-up` stage.

## Decisions

- Workers never merge. They stop at "ready to merge". The merge is the user's (2026-11-24).
- No tabs or "tab open" markers. The `start-task` skill does that with browser tab groups.

## Phase 6: gaps found against a task/PR app mock

The mock is built from the Linear ticket tree: parent → ticket → sub-issues → PRs. Each PR row has review detail. The items are in order of size, smallest first.

### 6.1 PR detail (built 2026-11-24)

Add these fields to `PR_FIELDS` in `lib/sources.mjs`:

- `additions`, `deletions`, `changedFiles`
- the number of unresolved `reviewThreads`
- check counts: passed, failed, pending. Today there is only the `statusCheckRollup` state.
- the viewer's pending review: the number of drafted comments
- bot review results

Show them on each PR line in the pane.

Bot reviews (decided 2026-11-24):

- `sentry-warden` is the agent review. It is a real security review. Show its result: the finding count, or "no problems".
- `cursor`, `sentry` (Seer) and `github-advanced-security` (CodeQL) are minor reviews, and a fuller review usually follows them. Do not show them as "reviewed". At most, show a small combined count.
- `linear-code`, `github-actions` and `getsantry` are not reviews.

### 6.2 Worker state

For each owner session, show whether it is running and when its turn started:

- band: "N workers running · 6m"
- row: an "Implementing · 6m" badge
- also show when a worker pushes and when CI runs on that push

The session files have no `isRunning` field. Infer the state from the file (decided 2026-11-24): a session is running when `latestUserFrameAt` is later than `lastTurnEdgeAt`, and the turn started at `latestUserFrameAt`. This is an internal format, so keep the check in one function and test it on real files.

### 6.3 Linear parent and children

Fetch the parent and the children with `linear api`. The pane then shows:

- the tree: the parent, this ticket, its sub-issues and their PRs
- progress, for example "2 of 6 done"
- the siblings under the same parent
- a Dispatch button on each sub-issue that has no PR

### 6.4 Task detail pane

An Overview pane for one task. Open it from a row in the board pane. It shows:

- the properties: status, priority, assignee, labels, project, cycle, team, branch
- the description
- the latest Linear comments
- the item tree from 6.3
