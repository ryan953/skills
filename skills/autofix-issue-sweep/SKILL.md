---
name: autofix-issue-sweep
description: Run Seer autofix across a set of Sentry issues, driving each through all steps (root cause → solution → code changes → PR). Use when asked to "run autofix on these issues", "seer autofix over a query", "autofix the awaiting-input queue", "batch autofix", or "sweep a project's issues with Seer". Prefers a stdlib script for fetching + iteration over per-issue inference.
allowed-tools: Bash, Read, mcp__sentry__search_issues, mcp__sentry__get_sentry_resource, mcp__sentry__analyze_issue_with_seer
---

# Autofix Issue Sweep

Run Seer autofix over many Sentry issues efficiently. The core idea: **let a script
do the fetching and iteration**, so you don't spend an inference round-trip per issue.
Reserve inference for the parts that actually need judgment — reviewing a specific
run's proposed fix, resolving conflicts between overlapping PRs, deciding whether a
fix is safe to merge.

## When to use the script vs. the MCP tool

| Situation | Use |
|-----------|-----|
| Many issues (5+), just need to trigger + track runs | `scripts/autofix_sweep.py` |
| Fetching the issue list from a query or URL | `scripts/autofix_sweep.py` |
| Need to read one run's root-cause/solution to judge it | `mcp__sentry__analyze_issue_with_seer` |
| Deep-dive a single issue before deciding | MCP tools |

The `mcp__sentry__analyze_issue_with_seer` tool returns the run's analysis inline,
which is great for one issue but expensive at scale. The script triggers runs and
reports status/PR links in one pass.

## Prerequisites

- **Auth token**: A Sentry auth token with `event:read` + `event:write` scopes
  (write is required to trigger autofix). Create one at
  https://sentry.io/settings/account/api/auth-tokens/. Provide it via the
  `SENTRY_AUTH_TOKEN` env var or `--token`. Never paste a real token into the repo,
  a commit, or the chat transcript.
- **Python**: Run under the repo venv: `.venv/bin/python`. The script is stdlib-only.

## Inputs

Accept any of these from the user and translate to script args:

| Input | Maps to |
|-------|---------|
| A Sentry issue-list URL | Parse `query`, `project`, `statsPeriod`, `sort` from the URL params |
| A search query string | `--query '<query>'` (+ `--project`, `--org`) |
| A list of issue short ids | `--issues ID1 ID2 ...` |

When given a URL like
`https://sentry.sentry.io/issues/?project=123&query=is%3Aunresolved+foo&sort=date&statsPeriod=30d`,
pull `project`, `query` (URL-decoded), `sort`, and `statsPeriod` straight out of it.

## Workflow

### 1. Dry run first (no mutations)

Always start read-only so the user sees the scope before anything triggers. Omit
`--run-to`:

```bash
.venv/bin/python .agents/skills/autofix-issue-sweep/scripts/autofix_sweep.py \
  --org sentry --project 4511567035432960 \
  --query 'is:unresolved [static-component-definitions]' --stats-period 30d
```

This lists each issue and its current autofix status (`no run`, `processing`,
`completed · PR <url>`, etc.). Present the count and how many already have runs/PRs.

### 2. Confirm, then trigger

Trigger the full pipeline to a PR. `--run-to open_pr` uses the API's `stopping_point`
so the server runs root_cause → solution → code_changes → open_pr automatically.
Use `--only-unstarted` to skip issues that already have a run:

```bash
.venv/bin/python .agents/skills/autofix-issue-sweep/scripts/autofix_sweep.py \
  --org sentry --project 4511567035432960 \
  --query 'is:unresolved [static-component-definitions]' --stats-period 30d \
  --run-to open_pr --only-unstarted
```

Runs are async. Add `--poll` to wait for each run to reach a terminal state and
capture PR links in the same invocation (slower; good for small batches).

Valid `--run-to` values: `root_cause`, `solution`, `code_changes`, `open_pr`.

### 3. Report

Summarize: total issues, how many triggered, how many already done, and the PR
links. **Call out issues that target the same file** — Seer opens one PR per issue,
so multiple issues in one file produce overlapping PRs that need manual
consolidation before merge. Group the results table by file to make this obvious.

## Hard rules

1. **Dry run before any trigger.** Show the plan and get explicit approval before
   running with `--run-to`. One approval covers the shown batch only.
2. **Never commit tokens.** The token is a runtime secret — env var or `--token`
   only, never written to a file in the repo or echoed into chat.
3. **Autofix only.** This skill triggers Seer runs and reports state. It does not
   resolve, assign, or otherwise mutate issue status.
4. **Overlapping PRs are the user's call.** When several issues share a file, do not
   assume the PRs can all merge. Flag them and let the user decide on consolidation.
5. **Respect rate limits.** The autofix POST endpoint is limited (≈25/min per user,
   100/hour per org). For large sweeps, batch and pause rather than firing hundreds
   at once.

## API reference (what the script calls)

- List issues: `GET /api/0/organizations/{org}/issues/?query=&project=&statsPeriod=&sort=&limit=`
- Trigger autofix: `POST /api/0/issues/{short_id}/autofix/` with
  `{"stopping_point": "open_pr"}` — `stopping_point` forces the run to start at
  root_cause and proceed automatically to that point.
- Read state: `GET /api/0/issues/{short_id}/autofix/` → `autofix.status`,
  `autofix.repo_pr_states` (PR urls), `autofix.blocks`.

See `src/sentry/seer/endpoints/group_ai_autofix.py` for the endpoint definition.
