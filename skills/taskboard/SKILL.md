---
name: taskboard
description: Keep one ledger of all your work - Linear tickets, your PRs, bot PRs made for you, review requests, jr (Junior) conversations, and Claude Code sessions - linked into tasks with a stage and suggested clean-up. Use when asked to "sync the taskboard", "what's on my plate", "show my tasks", "what needs me", "which sessions can I archive", "link my tickets and PRs", to "dispatch VDY-123", "send this task to a session", "start work on the next task", or to refresh the management session.
argument-hint: "[sync | show | task <id> | dispatch <id>]"
---

# Taskboard

One ledger links Linear issues, GitHub PRs, jr conversations and Claude Code sessions into tasks. The script does the fetching and linking; you only collect jr, read the report, and act on what the user approves.

Requires authenticated `gh`, the `linear` CLI, `node` 22+, and the jr MCP tools (`searchConversations`, `archiveConversation`).

| Command | Does |
|---|---|
| `node scripts/taskboard.mjs sync` | fetch Linear + GitHub + local Claude sessions, read the jr snapshot, link, save, print the report |
| `node scripts/taskboard.mjs sync --offline` | relink from the last fetch (after `ingest` or an override) |
| `node scripts/taskboard.mjs ingest jr <file>` | save a `searchConversations` result (status `active`) |
| `node scripts/taskboard.mjs show [--all] [--json]` | print the saved ledger; `--all` includes done tasks |
| `node scripts/taskboard.mjs task <task-id or item-key>` | one task with all its items, as JSON |
| `node scripts/taskboard.mjs join <a> <b>` / `split <key>` / `ignore <key>` | fix a wrong link, then `sync --offline` |
| `node scripts/taskboard.mjs dispatch <id> [--brief full\|review\|validate] [--route session\|jr\|new] [--step <text>]` | pick where the next step goes and write the message or brief, as JSON |
| `node scripts/taskboard.mjs assign <id> <item-key> [--notes <text>]` | record the session or jr conversation that works the task |
| `node scripts/taskboard.mjs detail <id>` | one task's Overview, fetched now: ticket properties, the latest 5 comments, the whole tree, items, as JSON |
| `node scripts/taskboard.mjs manager add\|remove <session-id>` | sessions that manage the board; they are never items |
| `node scripts/taskboard.mjs workers` | running sessions on open tasks, from local files only, as JSON |
| `node scripts/taskboard.mjs ask <item-key>` | the question to send to a session or jr conversation before it is archived |
| `node scripts/taskboard.mjs checked <item-key> [--remaining <text>]` | record its answer; no `--remaining` means nothing is left |

State lives in `~/.local/state/taskboard/` (`TASKBOARD_DIR` overrides): `ledger.json`, `overrides.json`, `checks.json`, `sources/`.

## Sync

1. Call jr `searchConversations` with `status: "active"`. Save the `conversations` array to a scratch file, keeping `conversationId`, `title`, `summary`, `status`, `treeState`, `turnActive`, `watching`, `lastSeenAt`, `url`. Keep each summary whole: the linker reads PR and ticket refs from it.
2. `node scripts/taskboard.mjs ingest jr <file>`
3. `node scripts/taskboard.mjs sync`
4. Show the user the report. Lead with **needs-you**, then the suggested actions, then the stage table. Do not restate every row; the report is already a table.

## Acting on suggestions

Every action needs the user's yes. Group them so one yes covers a kind (for example "archive these 12 sessions").

| Action | How |
|---|---|
| `check` | Ask first (see below). Never archive on a `check`. |
| `follow-up` | The conversation named work that is left (`reason`). Show it to the user. `dispatch` the task to send that conversation back to it. |
| `archive` jr | `archiveConversation` with `conversationId` and the item's `meta.lastSeenAt` |
| `archive` Claude session | `mcp__ccd_session_mgmt__archive_session` with the `local_…` id |
| `close-linear` | Linear MCP `save_issue` with the Done state, or tell the user to close it |
| `needs-you` | show the reason and a link; the user answers in that conversation or PR |

Then run `sync --offline` so the ledger shows the result.

### Ask before archive

A finished ticket or a merged PR does not prove that a conversation is finished. It can hold other PRs, follow-ups, or a question. So `archive` comes only from the conversation's own answer:

1. With the user's yes for the list of `check` items, send each one the `message` from `ask <item-key>`. For a session, use `SendMessage` to the `local_…` id. For jr, use `sendMessage`.
2. Read each reply: `list_events` for a session, `getConversation` for jr. A session that is still busy answers later. Read it on the next sync.
3. Record each reply: `checked <key>` for `NOTHING LEFT`, or `checked <key> --remaining "<what>"`. When a reply is unclear, record what it says as `--remaining`.
4. `sync --offline`. Then `check` becomes `archive` (nothing left) or `follow-up` (work is left; the task moves to the `follow-up` stage).

An answer is good only until the conversation is active again. New activity after `checked` gives a new `check`. A session that has any open PR in its own PR list gets no `check` and no `archive`.

Before you archive a Claude session, check it with `get_session`. Skip it if it is running, or if it has uncommitted work in a worktree.

## Dispatch

Dispatch sends a task's next step to a worker. Do it only for a task the user names, or after the user says yes to a list.

1. `node scripts/taskboard.mjs dispatch <id>`. Read `route`:

   | `route` | Do |
   |---|---|
   | `user` | Do not send. Tell the user `reason` (it waits for their answer, the merge is theirs, or an adhoc task needs `--step`). |
   | `session` | `SendMessage` (or `mcp__ccd_session_mgmt__send_message`) to `target.key` with `message`. A busy session queues it. |
   | `jr` | jr `sendMessage` to `target.key` with `message`. |
   | `new` | `mcp__ccd_session__start_session`: `initiation: "user_asked"`, `context: "fresh"`, `use_worktree: true`, and `title`, `prompt`, `background` from the output. Pass `cwd` only when it is not this project's folder. When `cwd` is null, ask the user for the folder. |

2. `node scripts/taskboard.mjs assign <id> <session or jr id>`. The owner is reused first next time, is never asked about as a duplicate, and stays in the task even when its title names nothing.
3. Put a new session in the sidebar group "Tasks": `list_groups`, then `create_group` if it is missing, then `move_sessions`.

Reuse order: the task owner, then the newest live Claude session, then the newest active jr conversation, then a new session. `--route` forces one.

Briefs (`--brief` overrides; the default comes from the task kind and stage):

- `full`: validate, fix, open a draft PR, iterate. It starts at the task's current stage.
- `review`: review with `deep-pr-review` (or `code-review` when it is not installed), draft the review, ask before it is posted. No code changes.
- `validate`: reproduce, report with screenshots, stop.

Every message has the same rules: never merge, ask before posting anything others see, commit only on the task's own branch, end each stop with one line of status. A worker stops at "ready to merge"; the merge stays with the user.

Sessions started from here report back when they end a turn. For a reused session or jr conversation, read its state with `get_session` and `list_events`, or jr `getConversation`, then `sync`.

## PR detail

Each open PR has a detail line in the report and the pane, for example `+81 −3 · 3 files · ✓38 ◌25 · 1 unresolved · warden: no problems`:

- size: lines added and removed, and the number of files
- checks: passed (✓), failed (✗) and pending (◌)
- the number of unresolved review threads
- `warden`: the agent review. It shows `running`, `N open of M`, or `no problems`.
- bot notes: unresolved threads from minor reviewers. The default is `cursor`, `sentry` (Seer) and `github-advanced-security`; `TASKBOARD_MINOR_REVIEWERS` overrides it. A fuller review usually follows these bots, so they do not count as a review.
- your draft review: the comments in your pending review

The detail comes from a second, batched query, only for open PRs, because a single search with these fields times out.

## Linear tree

The sync fetches each ticket's parent, its sub-issues and the parent's other sub-issues (the siblings). The tree is display data only. Sub-issues do not become items or tasks, because one parent can hold 80 of them.

- Progress: "18 of 73 done". Canceled sub-issues count toward neither side.
- The board lists only open sub-issues, and at most 10 open siblings, with a count for the others.
- A sub-issue with no PR attached can be dispatched. When no task tracks it, `dispatch <id>` makes a one-ticket task from the tree and writes a new-session brief.

## Mod: pane, band and timer

`mod/` is a Claude Code mod for the management session. Every session loads it, but it does nothing until `/board on` in that session.

- **`/board on`** runs the board in this session: it records the session in the mod's store (shared by all sessions, so the choice outlives a restart), runs `manager add` for it, starts the timers and opens the pane. **`/board off`** stops it and runs `manager remove`. **`/board`** opens the pane. In a session that is not on, there is no band, no timer and no CLI call.

- **Band** above the prompt: the counts (need you, follow-ups, to merge, iterate, review, to check, to archive), with **Board** and **Sync** buttons.
- **Backdrop:** a session with the board on gets a violet glow from the top-left corner, and every other session gets a faint blue wash at the bottom, so the management session stands out. Both use palette names, so they follow light and dark mode.
- **Pane** "Taskboard" (or `/board`): open tasks as cards (1, 2 or 3 columns, by the pane's width) in a tree that the script builds (`lib/group.mjs`, `sections` in `--board`):
  1. **Projects**: the Linear projects you lead or are a member of (shown even with no ticket of yours), and the project of any ticket on the board. Under each, its tickets' tasks.
  2. **Tickets with no project**, by the ticket's Linear team.
  3. **PRs with no ticket**, by GitHub repo, then your role (**Mine**: yours or a bot's made for you; **Review requested of you**; **Team review**, then the requested team that you are in; **Reviewed by you**; **Other PRs**), then the author: each bot by name (`sentry-junior` shows as jr, `seer-by-sentry` as seer) or **human** (**you** under Mine). The lone queue PRs are listed here too, as rows with their detail line.
  4. **Other**: tasks with no ticket and no PR, such as a lone session or jr conversation.

  A task's PRs show inside its card. The ▼/▶ button before each heading folds or unfolds what is under it (the heading, its count and "N need you" stay), and each open level is indented under its heading with a rail down its left side. Team review starts folded and the rest start open; a fold you change survives a reload. Names sort alphabetically; inside a group, cards sort by stage, most urgent first, and each card shows its stage. Each card has **Open** and **Dispatch** (it runs `/taskboard dispatch <id>`). A row with a Linear tree shows "↑ parent · N of M done" and a **Tree** button. The button opens the parent, the open sub-issues and the open siblings, and each one without a PR has its own **Dispatch**. **Overview** opens the task's detail pane (below). **Clean up** shows when there are actions to approve.
- **Overview pane:** one task, fetched when it opens, so the sync stays cheap. It shows the ticket's properties (status, priority, assignee, labels, project, cycle, team, branch), the pending actions, the items with PR detail, the description, the latest 5 comments, and the whole tree: the parent, every sub-issue and every sibling, finished ones dim. Each open sub-issue or sibling without a PR has **Dispatch**. The branch is the PR's head branch when there is a PR, and Linear's suggested `branchName` when there is none. A task with no ticket shows only its items.
- **Workers:** every minute it runs `workers`, which reads only local files. The band shows "N workers running · 6m" (the oldest turn). A row with a running session shows "Implementing · 6m" ("Validating", "Reviewing" or "Verifying" in those stages). A PR whose head commit is less than an hour old shows "pushed 3m ago", and its pending checks show as ◌ in the detail line.
- **Timer:** every 10 minutes it runs `sync --board` without model tokens. A toast shows when a task newly needs you or can merge, or when new clean-up shows up. Then the prompt box suggests `/taskboard`.

The timer cannot reach jr, because jr needs MCP tools. jr stays as of the last `/taskboard sync`.

It loads in every session through `CLAUDE_CODE_PLUGIN_DIRS` in the `env` block of `~/.claude/settings.json`, pointing at this folder's `mod/`. Only sessions started after that setting get it. `CLAUDE_CODE_PLUGIN_DIR_WATCH=1`, in the same `env` block, makes desktop sessions watch the folder: they are headless SDK sessions, which otherwise load the mod once at start. With it, saving a mod file reloads the mod in every running session, with no restart. When more than one session has the board on, a timer sync reuses a ledger that is less than 9 minutes old (`sync --max-age 540`), so only one session fetches each period. **Sync** always fetches. Tests: `claude plugin test mod`.

Manager sessions (`manager add`) are left out of the ledger, so the board never lists the session that runs it. `manager add` takes the app's `local_…` id or a CLI session id, which it looks up in the session files; the mod knows only the CLI id.

## How items link

- **Strong refs always link:**
  - a PR's branch, title and `Fixes`/`Closes`/`Resolves`/`Refs` lines
  - a Linear issue's attached PR links
  - the IDs and PR numbers in a jr or session title
  - a session's own PR list, when its title names nothing
- **Weak refs:** jr summaries and session summaries. Only the first one that names a tracked item links. A later mention is usually context ("VDY-445 is related but distinct").
- **Never used:** branch names a session wrote to. Sessions share checkouts, so one branch shows up in many unrelated sessions.
- **Bare `#123`** means `getsentry/sentry` only when it has 6 or more digits. Shorter numbers are another repo.
- **Archived repos:** PRs there are dropped at fetch time. They can never change.
- **Buckets:** a PR from a dependency bot (dependabot, renovate) goes to `queue`. So does a lone team review request (from CODEOWNERS), unless it changes a file whose path matches `TASKBOARD_WATCH` (default `onboarding|agent[_-]?handoff`, case-insensitive): then it is a review task. The match is made at fetch time, so after you change `TASKBOARD_WATCH`, run `sync`, not `sync --offline`. A lone ticket that you filed but that is not assigned to you goes to `backlog`. Neither becomes a task. The pane lists the open `queue` PRs under **PRs with no ticket**; `backlog` is only counted.

Stages, in report order: `needs-you`, `follow-up` (a conversation said work is left), `merge`, `iterate`, `review`, `fix`, `validate`, `verify` (PRs merged, ticket open), `adhoc` (only sessions or jr), `done`.

A task id comes from its lowest Linear ID, then its first PR, then its jr or session id. It stays the same across syncs. When tasks merge, the lower id is kept. The `owner`, `notes`, `titleOverride` and `kindOverride` fields carry over.

## Facts that cost time to find (2026-11-23)

- The session files have no running flag. A session is running when `latestUserFrameAt` is later than `lastTurnEdgeAt`, and the turn started at `latestUserFrameAt` (`turnState` in `lib/sources.mjs`). On 2026-11-24 this matched `list_sessions` `isRunning` for all 12 sessions that `list_sessions` listed.

- The desktop app keeps one JSON file per Code session under `~/Library/Application Support/Claude/claude-code-sessions/<account>/<org>/local_*.json`. The fields are `title`, `isArchived`, `prs`, `postTurnSummary` and `cliSessionId`. This is an internal format. Only the folder that holds the current session (matched on `CLAUDE_CODE_SESSION_ID`) is read, because other folders are other orgs that `list_sessions` does not show.
- `gh search prs --review-requested` includes team requests. In this account, all 42 open requests were team requests. `user-review-requested:` (in the raw query) finds direct requests only.
- Run the `linear` CLI from `$HOME`: inside a repo, direnv prints a banner before the JSON.
- Linear `createdIssues` includes every sub-issue that jr filed for you (80 under VDY-376). That is why lone filed tickets go to `backlog`.
- jr `searchConversations` has no archived flag in its result. `ingest` treats a conversation that left the active list as archived.

Tests: `node --test scripts/` and `claude plugin test mod`.
