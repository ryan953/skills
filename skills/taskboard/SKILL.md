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
| `nudge` | A ready PR of the user's (not a draft, not approved, no changes requested) has had no activity for `TASKBOARD_REVIEW_NUDGE_HOURS` (default 4). Offer to ask the team for review. Draft the request; send it only after the user approves the text. |

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

Every message has the same rules: never merge, ask before posting anything others see, commit only on the task's own branch, end each stop with one line of status. A worker stops at "ready to merge"; the merge stays with the user. Every message also ends with the close-out questions (see Manage).

Sessions started from here report back when they end a turn. For a reused session or jr conversation, read its state with `get_session` and `list_events`, or jr `getConversation`, then `sync`.

## Manage

A session with `/board on` is the manager. The mod adds a short manager section to its system prompt while the board is on; this section is the playbook. The manager makes sure that each task is considered and moved forward. It does not judge the quality of the work, and it does not redo it.

1. **Start work in a sub-session.** For a task the user names: `dispatch`, then start the session with a good brief (the `/spawn` rules: the user's words, where, what done looks like, rules, landing), then `assign`. A piece of the current conversation is a fork; a new task is fresh.
2. **Close-out.** Every dispatch message and brief ends with six questions. The worker answers each one with yes or no and one line when it stops:
   - Implementation: is a code change needed, or is this done, not a bug, or out of scope?
   - Review: is more review needed (the agent review, bot threads, a `deep-pr-review` pass)?
   - Tests: are the tests enough? Which ones were added or run?
   - Skills: which of the user's skills apply, and were they used? To name them, read the skills list in this session.
   - Sign-off: does this need the user's review, or a review request to the team?
   - Next step: what is it, and who owns it: the worker, the user or the team?
3. **When a worker's report comes back** (a side-session note, or `get_session` and `list_events` for a reused session), check only that each question has an answer and that the next step has an owner. If an answer is missing, `SendMessage` the worker and name the missing question. Do not grade the answers.
4. **Move it forward.** A next step that the worker owns, on a task the user named: send it with `dispatch`, without asking. A next step that the user or the team owns goes on the list in step 6.
5. **Review nudge.** A `nudge` action means that a ready PR has had no activity for some hours. Offer to ask the team for review, and draft the request.
6. **End each turn with what needs the user:** answers a worker waits for, merges, review requests to send, clean-up to approve, and workers that stopped with no next step. Run `workers` to see which ones are still running.

| The manager may do alone | It needs the user's yes | Never |
|---|---|---|
| sync, and read sessions, PRs and tickets | start work on a task the user did not name | merge a PR |
| `dispatch` and `assign` for a task the user named | archive a session or jr conversation (ask before archive) | post as the user without a yes for that text |
| send a worker its next step, or ask it for a missing close-out answer | a review request to a person or a team, Slack or Linear posts | approve a permission prompt for a worker |
| `checked`, `join`, `split`, `ignore` | a Linear state change on a ticket not assigned to the user | |

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

- **Band** above the prompt: the counts (need you, follow-ups, to merge, iterate, review, to check, to archive, to close, to nudge), with **Board** and **Sync** buttons.
- **System prompt:** while the board is on, the mod adds a short `taskboard:manager` section to the session's system prompt (`prompt.compose`). It holds the manager's stance and its approval rules, and points to the Manage section above. `/board off` removes it.
- **Manager marker:** a session with the board on shows `◆ Taskboard manager` in the status line under the prompt and an inverse **Manager** badge first in the band, on every surface. On desktop it also gets a still violet pinstripe backdrop and a violet frame on the user's messages; a build that refuses the message style gets the backdrop alone. Every other session gets a faint blue wash at the bottom. All of them use palette names, so they follow light and dark mode. `/board off` clears the status line and goes back to the wash.
- **Pane** "Taskboard" (or `/board`): open tasks as cards (1, 2 or 3 columns, by the pane's width) in a tree that the script builds (`lib/group.mjs`, `sections` in `--board`):
  1. **Projects**: the Linear projects you lead or are a member of (shown even with no ticket of yours), and the project of any ticket on the board. Under each, its tickets' tasks.
  2. **Tickets with no project**, by the ticket's Linear team.
  3. **PRs with no ticket**, by GitHub repo, then how the PR involves you (**Your PRs**: yours or a bot's made for you; **Review requested of you**; **Team review**, then the requested team that you are in; **You reviewed**; **Other PRs**), then the author: each bot by name (`sentry-junior` shows as jr, `seer-by-sentry` as seer) or **human**. A caption under the section title says this. A level that only repeats its parent is left out: your own PRs sit straight under **Your PRs** (only bots get a level there, as in "Your PRs > jr"), and a team review for one team is one heading, **Team review: app-frontend**. The lone queue PRs are listed here too, as rows with their detail line.
  4. **Other**: tasks with no ticket and no PR, such as a lone session or jr conversation.
  5. **Unsubscribed**: PRs with no ticket that you unsubscribed from or ignored. It starts folded, no count or filter includes it, and it is hidden while a filter is picked.

  A task's PRs show inside its card. A card with no ticket sits under the repo of its first open PR, so when it holds two or more PRs, a line under them names the items that link them ("Linked: both PRs are named by 3 Claude sessions"). The ▼/▶ button before each heading folds or unfolds what is under it (the heading, its count and "N need you" stay), and each open level is indented under its heading with a rail down its left side. Team review starts folded and the rest start open; a fold you change survives a reload. Filter buttons under the header (**Needs you**, **Follow-up**, **Ready to merge**, each with its count) show only tasks in those stages and add up when you pick more than one. **All others** shows every other stage and the lone PRs, **All** clears the filters, and groups with nothing left are hidden. Names sort alphabetically; inside a group, cards sort by stage, most urgent first, and each card shows its stage. Each card has **Open** and **Dispatch** (it runs `/taskboard dispatch <id>`). A row with a Linear tree shows "↑ parent · N of M done" and a **Tree** button. The button opens the parent, the open sub-issues and the open siblings, and each one without a PR has its own **Dispatch**. **Overview** opens the task's detail pane (below). **Clean up** shows when there are actions to approve. It sends the clean-up request (`/taskboard clean up` and the whole flow, so a new session can act on it) to a desktop session kept for clean-up, never to the session that draws the pane. The mod's store remembers that session. If it is archived or gone, or none is kept yet, the button starts a new one with `start_session`, detaches it (so the app does not wake the manager at the end of each of its turns), and runs `manager add` for it. A toast names the session.
- **Overview pane:** one task, fetched when it opens, so the sync stays cheap. It shows the ticket's properties (status, priority, assignee, labels, project, cycle, team, branch), the pending actions, the items with PR detail, the description, the latest 5 comments, and the whole tree: the parent, every sub-issue and every sibling, finished ones dim. Each open sub-issue or sibling without a PR has **Dispatch**. The branch is the PR's head branch when there is a PR, and Linear's suggested `branchName` when there is none. A task with no ticket shows only its items.
- **Workers:** every minute it runs `workers`, which reads only local files. The band shows "N workers running · 6m" (the oldest turn). A row with a running session shows "Implementing · 6m" ("Validating", "Reviewing" or "Verifying" in those stages). A PR whose head commit is less than an hour old shows "pushed 3m ago", and its pending checks show as ◌ in the detail line.
- **Timer:** every 10 minutes it runs `sync --board` without model tokens. A toast shows when a task newly needs you or can merge, when new clean-up shows up, or when more PRs wait for a review nudge. Then the prompt box suggests `/taskboard`.

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
- **Unsubscribed:** a PR with no ticket goes to `unsubscribed` (a lone queue PR) or gets `unsubscribed: true` (a task whose open PRs are all unsubscribed) when you unsubscribed from it or ignored it. A PR under a ticket stays with the ticket. GitHub's `viewerSubscription` is `UNSUBSCRIBED` also for a PR you were never subscribed to, so only `IGNORED`, or `UNSUBSCRIBED` with your own `UnsubscribedEvent` as your latest subscribe event in the timeline, counts.

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
