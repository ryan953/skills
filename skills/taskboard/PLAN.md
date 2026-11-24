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

### 6.1 PR detail (built 2026-11-24, as a second batched query, not in `PR_FIELDS`)

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

### 6.2 Worker state (built 2026-11-24)

For each owner session, show whether it is running and when its turn started:

- band: "N workers running · 6m"
- row: an "Implementing · 6m" badge
- also show when a worker pushes and when CI runs on that push

The session files have no `isRunning` field. Infer the state from the file (decided 2026-11-24): a session is running when `latestUserFrameAt` is later than `lastTurnEdgeAt`, and the turn started at `latestUserFrameAt`. This is an internal format, so keep the check in one function and test it on real files.

### 6.3 Linear parent and children (built 2026-11-24)

As built: the tree is display data, not items. The board lists only open sub-issues and at most 10 open siblings, behind a **Tree** button, so a parent with 80 sub-issues does not fill the pane. The full sibling list can go in the 6.4 detail pane.

Fetch the parent and the children with `linear api`. The pane then shows:

- the tree: the parent, this ticket, its sub-issues and their PRs
- progress, for example "2 of 6 done"
- the siblings under the same parent
- a Dispatch button on each sub-issue that has no PR

### 6.4 Task detail pane (built 2026-11-24)

As built: the Overview is fetched with `detail <id>` when it opens (about 1 s), not on every sync. A review task with no ticket shows only its items and their PR detail.

An Overview pane for one task. Open it from a row in the board pane. It shows:

- the properties: status, priority, assignee, labels, project, cycle, team, branch
- the description
- the latest Linear comments
- the item tree from 6.3

## Phase 7: the tree is the board, and it re-opens sessions

The user's ask (2026-11-24): use the mock's tree view (project → ticket → PR) as the main board, and use the tree to re-open existing sessions for a task.

Today the board is a flat list by stage, and each task's tree is behind a **Tree** button. `project` is fetched only by `detail`, and `TreeNode` has no sessions.

### 7.1 Tree view as the default

The stage list stays as a second view or a filter.

- **Level 1, the group.** Start from the team/project grouping that the "Taskboard grouping by team/project" session is building (`lib/group.mjs`, `taskGroup`). Do not build a second grouping. Tasks with no project go under "No project". Review tasks with no ticket go under their repo, or under "Reviews".
- **Level 2, the parent ticket.** Show the parent's progress ("2 of 6 done"), then the tickets and sub-issues under it. "This ticket" is highlighted. Each task has a stage badge (needs-you, merge, iterate…), so the stage order is not lost.
- **Level 3, the PRs.** Each ticket's PRs are nested cards with the 6.1 detail line: checks, threads, review.
- **Done tickets** (decided 2026-11-24): they stay visible, collapsed to one line with the merged PR. Only open work expands by default.
- **Siblings:** an "Also under <parent>" line of sibling chips.

### 7.2 Sessions on the tree nodes

- Each `TreeNode` and each task row gets the Claude sessions and jr conversations that link to it: the owner first, then the others, newest first.
- Each one shows its title, whether it is running (6.2), and whether it is archived.
- A session goes on the PR node when its `prs` list names that PR. If not, it goes on the ticket node.
- A ticket with no session of its own shows its parent's or children's sessions in a secondary "related" list, so a session for the same feature can be reused.
- Archived sessions must be read too. Today the sync reads them, but the board does not show them.

### 7.3 Re-open from the tree

Each node gets one main button:

- **Open**, when a live session exists: the session opens in a **split view** beside the management session (decided 2026-11-24).
  - First test whether a mod `<Link href>` with the session's `link` (`claude://claude.ai/epitaxy/local_…`) opens it with no model turn. A link likely opens the session focused, not split.
  - If it does not split, run `/taskboard open <task-id>`. The skill then calls `mcp__ccd_window__open_session_in` with split view.
- **Resume**, when the only session is archived: `/taskboard open <task-id>` calls `unarchive_session`, then opens the session in a split view. It asks the user **each time**, as for archive (decided 2026-11-24).
- **Dispatch**, when there is no session: the existing reuse rule.
- **jr conversations:** an **Open** link to their `url`.
