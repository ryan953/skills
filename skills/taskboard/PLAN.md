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

Built 2026-11-24 as the user asked it: projects → your tickets → their PRs; tickets with no project by team; PRs with no ticket by repo → role → team → author; then Other. The parent-ticket level below is not built.

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

## Phase 8: merge order, Linear status, Overview activity

More gaps from the mock analysis (2026-11-24).

### 8.1 Merge order between PRs

In the mock, a `sentry` UI PR needs a `getsentry` API PR in the same task. Neither the mock nor the taskboard shows that the API PR must merge first.

- Find tasks that have open PRs in more than one repo.
- **How the order is known** (decided 2026-11-24):
  - a `Depends on <PR>` or `Requires <PR>` line in the PR body
  - an `order <a> <b>` override, stored like `join`, which wins over the body
- Show "merge <PR> first" on the PR that must wait, and keep that PR out of the `merge` stage until the other PR merges.

### 8.2 Linear status on dispatch

In the mock, a ticket showed "Planned" while an agent was "Implementing" it.

- When dispatch starts a worker on a ticket in Backlog, Planned, Triage or Todo, move the ticket to the team's In Progress state with Linear MCP `save_issue`.
- Statuses are different for each team, so read them with `list_issue_statuses`.
- **Approval** (decided 2026-11-24): the user's yes to the dispatch also covers the status move for a ticket assigned to the user. A ticket assigned to someone else, or to no one, still gets its own question.

### 8.3 Activity and a comment box in the Overview pane

- **Activity timeline** (decided 2026-11-24): merge Linear history (status changes, PR links and merges) with taskboard events. The taskboard writes an event log when it dispatches, archives, resumes or records a check, because those events are not in Linear.
- **Comment box:** a button that runs `/taskboard comment <id>`. The skill drafts the comment, and writes it with `save_comment` only after the user approves the text.

### Decisions recorded with phase 8

- The managers list holds only sessions that manage the board. A session that changes into a worker is removed from it (2026-11-24: `local_870120ee` was removed, the newest "Taskboard" session was added).

## Phase 9: the management session

The user's ask (2026-11-24): mark the management session clearly, and make it a manager and delegator. Tasks are forked or spawned from it, and it moves them forward. **The manager makes sure that each question is considered and each step is done. It does not judge the quality of the work.**

### 9.1 Marker (built 2026-11-24)

- Desktop: a still, tiled pinstripe ground (`vector`, `surface-0` with `bg-pro` stripes) in place of the radial glow, and a violet `border-pro` frame on the user's messages (`style.UserMessage`). A build that refuses `style` gets the ground alone. Workers keep the faint blue wash.
- Every surface: the status line `◆ Taskboard manager` (`$.ui.status`), cleared by `/board off`, and an inverse **Manager** badge first in the band.
- Not done: the session title. A mod sets a title only through the classic `SessionStart` or `UserPromptSubmit` `sessionTitle`, and it is not known whether the desktop sidebar shows it. `/board on` runs no model turn, so it cannot call `set_session_title`.

### 9.2 Manager behavior: options

| | Agent definition (`agents/manager.md`) | `prompt.compose` section from the mod | Skill (`taskboard` gets a "Manage" section) |
|---|---|---|---|
| Turns on | only at session start (`--agent`, `agentType`); the desktop Code tab has no picker for a running session | at `/board on`, off at `/board off`, in that session only | when the model loads the skill: on a `/taskboard` command or a match on its description |
| Always in force | yes | yes | no: it leaves the context at compaction, and a turn that does not load it does not follow it |
| Cost | its prompt replaces the whole system prompt, so it loses Claude Code's own sections unless it copies them | one short `session` section after the cache boundary; one cache miss at each on and off | nothing until it is loaded |
| Fits what exists | no: the session already exists when `/board on` runs | yes: same switch as the band, backdrop and timers | yes: dispatch, `assign`, ask-before-archive and `workers` are already there |

**Recommendation: `prompt.compose` plus the skill.** The mod adds a short section (about 15 lines) only while the board is on: the stance, the close-out questions, and the approval rules below. It says "read the Manage section of the taskboard skill before you dispatch or relay". The skill holds the long playbook, so the always-on part stays small. The agent definition fails on the first row: the user turns a running session into a manager. A `$.agent.register` subagent type has the same problem, because it is a subagent and not the session itself.

### 9.3 What the manager does

1. **Start work.** For a task the user names: `dispatch <id>`, then `start_session` (the `/spawn` brief rules: the user's words, where, done looks like, rules, landing), then `assign`. A related piece of the current conversation is a fork; a new task is fresh.
2. **Every brief ends with a close-out block.** Each worker answers it in the report that ends its turn, with yes or no and one line each:
   - Is implementation needed, or is this already done or not a bug?
   - Is more review needed (agent review, bot threads, `deep-pr-review`)?
   - Are the tests enough for the change? Which tests were added or run?
   - Which of the user's skills apply (`commit`, `pr-writer`, `iterate-pr`, `deep-pr-review`, `verify-sentry`, `agent-browser`, `frontend-conventions`, …), and were they used?
   - Does this need the user's review, or a review request to the team?
   - The next step, and who owns it: the worker, the user or the team.
3. **When a side-session note comes back**, the manager checks only that each close-out question has an answer and that the next step is named. A missing answer goes back to the worker with `SendMessage` ("you did not say whether the tests are enough"). The manager does not grade the answers or redo the work.
4. **Move it forward.** A next step owned by the worker gets the next `dispatch` without asking (the dispatch is to a session this manager started for a task the user named). A next step owned by the user or the team goes on the needs-you list.
5. **Review nudge.** A PR that is ready for review and has no review activity for `TASKBOARD_REVIEW_NUDGE_HOURS` (default 4) gets a `nudge` action in the script, so the timer toasts it. The manager then asks the user: "ask the team for review on #123?" It drafts the request; it never sends it alone.
6. **Raise what needs the user**, in one list at the end of each turn: answers it waits for, merges, review requests to send, clean-up to approve, workers that stopped without a next step.

### 9.4 What the manager may do alone, and what needs the user's yes

| Alone | Needs the user's yes | Never |
|---|---|---|
| sync, read sessions, PRs and tickets | start a session for a task the user did not name | merge a PR |
| `dispatch` and `assign` for a task the user named | archive a session or jr conversation (ask before archive) | post a review, comment or message as the user without a yes for that text |
| send a worker its next step, or ask it for a missing close-out answer | a review request to a person or a team, Slack or Linear posts | approve a permission prompt for a worker |
| `checked`, `join`, `split`, `ignore` | a Linear state change on a ticket not assigned to the user (8.2) | |

### 9.5 Build steps, once an option is picked

- Mod: `prompt.compose` hook that appends `taskboard:manager` (`scope: 'session'`) when `enabled`; a test that the section is present only while the board is on.
- `lib/dispatch.mjs`: the close-out block in `RULES` (session messages and new-session briefs); tests.
- Script: the `nudge` action and `TASKBOARD_REVIEW_NUDGE_HOURS`; the band and pane count it.
- `SKILL.md`: a "Manage" section with 9.3 and 9.4.
- No file in dotFiles is needed for this option. The agent-definition option would add `templates/.claude/agents/taskboard-manager.md` there.
