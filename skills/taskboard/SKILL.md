---
name: taskboard
description: Keep one ledger of all your work - Linear tickets, your PRs, bot PRs made for you, review requests, jr (Junior) conversations, and Claude Code sessions - linked into tasks with a stage and suggested clean-up. Use when asked to "sync the taskboard", "what's on my plate", "show my tasks", "what needs me", "which sessions can I archive", "link my tickets and PRs", or to refresh the management session.
argument-hint: "[sync | show | task <id>]"
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

State lives in `~/.local/state/taskboard/` (`TASKBOARD_DIR` overrides): `ledger.json`, `overrides.json`, `sources/`.

## Sync

1. Call jr `searchConversations` with `status: "active"`. Save the `conversations` array to a scratch file, keeping `conversationId`, `title`, `summary`, `status`, `treeState`, `turnActive`, `watching`, `lastSeenAt`, `url`. Keep each summary whole: the linker reads PR and ticket refs from it.
2. `node scripts/taskboard.mjs ingest jr <file>`
3. `node scripts/taskboard.mjs sync`
4. Show the user the report. Lead with **needs-you**, then the suggested actions, then the stage table. Do not restate every row; the report is already a table.

## Acting on suggestions

Every action needs the user's yes. Group them so one yes covers a kind (for example "archive these 12 sessions").

| Action | How |
|---|---|
| `archive` jr | `archiveConversation` with `conversationId` and the item's `meta.lastSeenAt` |
| `archive` Claude session | `mcp__ccd_session_mgmt__archive_session` with the `local_…` id |
| `close-linear` | Linear MCP `save_issue` with the Done state, or tell the user to close it |
| `needs-you` | show the reason and a link; the user answers in that conversation or PR |

Then run `sync --offline` so the ledger shows the result.

Before you archive a Claude session, check it with `get_session`. Skip it if it is running, or if it has uncommitted work in a worktree.

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
- **Buckets:** a lone team review request (from CODEOWNERS) goes to `queue`. A lone ticket that you filed but that is not assigned to you goes to `backlog`. Both are counted, not listed.

Stages, in report order: `needs-you`, `merge`, `iterate`, `review`, `fix`, `validate`, `verify` (PRs merged, ticket open), `adhoc` (only sessions or jr), `done`.

A task id comes from its lowest Linear ID, then its first PR, then its jr or session id. It stays the same across syncs. When tasks merge, the lower id is kept. The `owner`, `notes`, `titleOverride` and `kindOverride` fields carry over.

## Facts that cost time to find (2026-11-23)

- The desktop app keeps one JSON file per Code session under `~/Library/Application Support/Claude/claude-code-sessions/<account>/<org>/local_*.json`. The fields are `title`, `isArchived`, `prs`, `postTurnSummary` and `cliSessionId`. This is an internal format. Only the folder that holds the current session (matched on `CLAUDE_CODE_SESSION_ID`) is read, because other folders are other orgs that `list_sessions` does not show.
- `gh search prs --review-requested` includes team requests. In this account, all 42 open requests were team requests. `user-review-requested:` (in the raw query) finds direct requests only.
- Run the `linear` CLI from `$HOME`: inside a repo, direnv prints a banner before the JSON.
- Linear `createdIssues` includes every sub-issue that jr filed for you (80 under VDY-376). That is why lone filed tickets go to `backlog`.
- jr `searchConversations` has no archived flag in its result. `ingest` treats a conversation that left the active list as archived.

Tests: `node --test scripts/`.
