---
name: worktree-janitor
description: Remove linked git worktrees under ~/code/* whose work is already safe on GitHub (merged, closed, or open PR, or simply pushed). Use when asked to "clean up worktrees", "prune worktrees", "remove merged worktrees", "reclaim worktree disk space", or when a scheduled run fires. Never touches a primary worktree, a dirty tree, or work that exists only locally.
allowed-tools: Bash, Read
---

# Worktree Janitor

Linked worktrees pile up. Each one under `~/code/sentry` or `~/code/seer` costs
roughly 2 GB, because `node_modules` and `.venv` are per-worktree. This skill
removes the ones that no longer hold anything unique.

**The governing rule: if every commit is on GitHub, the worktree is disposable.**
It can always be re-created. If any commit exists only on this machine, the
worktree stays, whatever its PR says.

## Install

The skill itself is distributed by dotagents: `~/.agents/agents.toml` pulls
`name = "*"` from `ryan953/skills`, so `dotagents install` places this directory
at `~/.agents/skills/worktree-janitor`.

dotagents manages skills, MCP servers, hooks, subagents, and plugins. It does
**not** manage macOS LaunchAgents. So the hourly schedule is a separate, explicit
step — run once after installing the skill:

```bash
bash ~/.agents/skills/worktree-janitor/install/install.sh
```

That renders the LaunchAgent from `install/*.plist.template`, pointing it at
whichever copy of the skill the installer was run from, and registers it. It is
idempotent — re-run it to change the schedule or repair the registration:

```bash
bash install/install.sh --minute 12   # a different slot
bash install/install.sh --dry-run     # print the plist, change nothing
bash install/uninstall.sh             # deregister, keep the logs
```

**Re-run `install.sh` after a `dotagents install` that moves the skill.** The
plist stores an absolute path to `scripts/run-scheduled.sh`. If you install the
LaunchAgent from a development checkout and later switch to the dotagents-managed
copy, the old path is what stays registered.

## Running it

```bash
# Report only. Changes nothing. Always start here.
bash scripts/janitor.sh

# Do the removals.
bash scripts/janitor.sh --apply
```

`scripts/run-scheduled.sh` is the LaunchAgent entry point. It only adds what a
LaunchAgent lacks — a usable `PATH` and a `GITHUB_TOKEN` from `gh auth token` —
then calls `janitor.sh --apply`. Do not put logic in it.

| Flag | Effect |
|------|--------|
| `--apply` | Perform removals. Without it the script only reports. |
| `--keep-branch` | Remove the worktree but keep the local branch. |
| `--ignore-cwd` | Ignore the "a process is inside it" guard (see below). |
| `--root DIR` | Scan somewhere other than `~/code`. |
| `--json` | Machine-readable output, for a scheduled run that must summarize. |

## How a worktree is judged safe

A worktree is removed only when it clears **every** gate:

1. It is a **linked** worktree, not the repo's primary one.
2. It is not `locked`, and not on a detached HEAD.
3. `git status --porcelain` is empty. No modified, staged, or untracked files.
4. No running process has its working directory inside it.
5. Its HEAD is provably on GitHub, by one of two routes:
   - **A PR whose `headRefOid` equals local HEAD.** Any state counts, including
     `OPEN` — an open PR means the commits are pushed, and the branch can be
     pulled again if CI fails or review comments arrive.
   - **`origin/<branch>` exists and contains HEAD** (`merge-base --is-ancestor`).

When a worktree is removed, its local branch is deleted too, unless another
worktree still has that branch checked out or `--keep-branch` is set.

## Traps this skill is built around

These are real properties of the setup, learned the hard way. Do not "simplify"
them away.

- **Never trust `@{upstream}`.** In this setup branch `seer-embed-logging`
  tracked `origin/master`, and `pr7795-trigger` tracked
  `origin/worktree-autofix-ref-embed`. `@{upstream}..HEAD` was therefore `0` for
  branches that were never pushed at all. Compare against
  `refs/remotes/origin/<branch>` by exact name, or against the PR head SHA.
- **A missing remote branch does not mean unpushed work.** GitHub deletes the
  branch when a PR merges, so every merged worktree shows no remote branch. Use
  the PR's `headRefOid`, which survives the branch deletion.
- **`git stash list` is repo-wide, not per-worktree.** The stash lives in the
  common git dir. All six `sentry` worktrees reported the same 35 stashes. It is
  useless as a per-worktree signal — do not gate on it.
- **The same branch name can appear in two different repos** with different PR
  states (`worktree-autofix-ref-embed` was merged in `sentry` and open in
  `seer`). Always scope the PR lookup to that worktree's own `origin`.
- **Removal deletes `node_modules` and `.venv`.** That is the point — it is where
  the ~2 GB lives — but returning to the branch means a full reinstall. It is
  also why a run takes minutes: each tree holds ~200k files.
- **Do not depend on the executable bit.** dotagents materializes skill files by
  copy. Every entry point here is invoked as `bash <script>`, and the LaunchAgent
  runs `/bin/bash <runner>` rather than the script directly.

## The cwd guard

Gate 4 skips a worktree when any process sits inside it. The report names the
holder, for example `in use by zsh (pid 2740)`.

This is deliberately conservative, and it has one failure mode: a long-lived
daemon whose working directory happens to be parked there (`limactl` did this)
will block that worktree forever. When the report shows a holder you know is
irrelevant, re-run with `--ignore-cwd`.

## Undo

Every removal is appended to `~/.claude/worktree-janitor.log` with a restore
command and the exact SHA:

```
git -C '/Users/ryan953/code/sentry' worktree add --detach '<path>' <sha>   # branch was: <branch>
```

The commits stay in the repository's object store until `git gc` runs, and the
PR holds them on GitHub regardless. To get the branch back by name instead:

```bash
git -C ~/code/<repo> fetch origin
git -C ~/code/<repo> worktree add <path> <branch>
```

## Concurrency

The script takes an atomic `mkdir` lock at `~/.claude/worktree-janitor.lock`,
with a 55-minute lease so a crashed run cannot hold it forever. A second run
that finds the lock held exits immediately rather than waiting. This matters
because the hourly schedule can overlap a long manual run.

## Hard rules

1. **Report before applying.** When a person asks for cleanup interactively, show
   the plan first. `--apply` acts on what the report showed.
2. **Never remove a primary worktree**, whatever its PR state.
3. **Never remove work that is only local.** No PR and not pushed means keep, even
   if the worktree is old and clean.
4. **Never use `git worktree remove --force`.** Git's own refusal is the last
   safety net. If git objects, report it and move on.
5. **Report what was kept and why.** A silent skip is a bug — the reason is how
   the user learns a worktree needs their attention.
