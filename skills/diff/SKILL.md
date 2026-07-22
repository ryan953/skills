---
name: diff
description: Review a diff in revdiff, opened in a persistent tmux window, with the diff range inferred automatically. Use when asked to "diff", "review diff", "review my changes", "review the branch", "revdiff in a window", "compare to <ref>", or to review changes without specifying two explicit commits. Defaults to the full current-branch-vs-main range and never steals terminal focus.
allowed-tools: Bash, Read, Monitor
---

# diff — windowed diff review with inferred range

Open [revdiff](https://github.com/umputun/revdiff) on an inferred diff range in a
**persistent tmux window**, capture the reviewer's inline annotations, and address them.

This is a leaner alternative to the stock `revdiff` launcher for two reasons that matter
in a headless / background agent shell:

1. **No terminal guessing.** The stock launcher probes agterm → tmux → zellij → kitty → …
   and, in a background job (no `$TMUX`, no controlling TTY), fails with
   `no overlay terminal available`. This skill talks to the running tmux server directly.
2. **Range is inferred, not asked.** You almost never pass two commits. With no args this
   defaults to the **whole current branch vs. its main branch** — the range you actually
   want — instead of prompting.

The window is created with `-d` (detached): it never steals focus, survives client
disconnects (SSH/tmux drop), and the reviewer switches to it on their own schedule
(`Ctrl-b <n>` or `Ctrl-b w`).

## Step 0: verify revdiff

```bash
command -v revdiff || echo "install: brew install umputun/apps/revdiff"
```

## Step 1: launch

Resolve this skill's script directory (installed user-scope, or from a repo checkout):

```bash
DIFF="$HOME/.claude/skills/diff/scripts/diff.sh"
[ -f "$DIFF" ] || DIFF="$HOME/.agents/skills/diff/scripts/diff.sh"
[ -f "$DIFF" ] || DIFF="$(git -C ~/code/skills rev-parse --show-toplevel 2>/dev/null)/skills/diff/scripts/diff.sh"
```

Run the launcher with the user's argument (verbatim), or no argument for the implied range:

```bash
"$DIFF" [ARGS]
```

Argument forms:

| User said | Pass | Diffs |
|---|---|---|
| "review my changes" / "diff" / nothing | *(no args)* | inferred range (below) |
| "compare to master" / "diff HEAD~3" | `master` / `HEAD~3` | that ref → working tree |
| "diff A to B" / "diff A B" | `A B` | explicit two-ref range |
| "review this file" / a path | `path/to/file.tsx` | single file, context-only |

**Inferred range (no args)** — `diff.sh` decides:
- **feature branch** → `git merge-base <main> HEAD` → HEAD, i.e. the *entire branch diff vs main*, including uncommitted work. This is the default and the common case.
- **on main, dirty** → uncommitted working-tree changes.
- **on main, clean** → `HEAD~1` (last commit).

The launcher prints `KEY=VALUE` lines. Capture them:

```bash
eval "$("$DIFF" $ARGS)"   # sets WID OUT DONE WINDOW SOCKET RANGE
```

Then tell the user which tmux window to switch to, e.g.:
> revdiff is open in tmux window **`$WINDOW`** (`$RANGE`). Switch with `Ctrl-b <n>` or `Ctrl-b w`, annotate the lines you want changed, then quit revdiff (`q`).

## Step 2: wait for the review to finish

The launcher returns immediately (the window runs in the background). Wait for the
completion sentinel with a Monitor, **not** a blocking bash command:

```
Monitor: until [ -f "$DONE" ]; do sleep 1; done; echo "review finished"
```

The `$DONE` file appears the instant revdiff exits (it holds revdiff's exit code). Do not
poll in a foreground bash call and do not relaunch — the window is durable, so if anything
times out the annotations are still on disk.

## Step 3: read annotations

```bash
[ -s "$OUT" ] && cat "$OUT" || echo "no annotations — review complete"
```

Output format (one block per annotation):

```
## file.tsx:43 (+)
use the shared hook here instead

## store.ts:18 (-)
don't drop this validation
```

`(+)` added line, `(-)` removed line, `(file-level)` whole-file note.

## Step 4: classify & act

- **Explanation request** — text starts with `explain`/`describe`/`what is`/`how does`/`clarify`
  or contains `??`. Answer it in chat (read the referenced code first). Don't edit code.
- **Code-change directive** — everything else. Summarize the planned edits, get a quick
  confirm if non-trivial, then apply them.

## Step 5: loop

After edits, relaunch with the **same** args so the reviewer sees the new state:

```bash
eval "$("$DIFF" $ARGS)"
```

Quit with no annotations → review complete.

## Reference: why the raw-tmux recipe (not env in settings.json)

The launch needs values that mostly can't be baked into `~/.claude/settings.json`:

- `REVDIFF_EXIT_CODE_ON_ANNOTATIONS=true` — the one truly static value. An **env var**,
  not a CLI flag (an old revdiff binary would reject the flag). Set inside the window's
  command so it applies to revdiff only.
- **tmux socket** — `/tmp/tmux-$(id -u)/default` (macOS may resolve it under `/private/tmp`).
  `id -u` is stable but the *server must be running*; `diff.sh` prefers an inherited `$TMUX`
  and otherwise probes `$TMUX_TMPDIR`, `/tmp`, `/private/tmp` for a live server (short-circuits
  on the first hit — normally a single `tmux list-sessions`).
- `--output=<file>` — per-run temp path (job-local under `$CLAUDE_JOB_DIR/tmp`).
- The stock launcher's window mode also wants `TMUX=<socket>,<server_pid>,<session_id>`
  reconstructed and `REVDIFF_TMUX_WINDOW=1`. Even then it returned instantly without opening
  a window in testing, which is why `diff.sh` drives `tmux new-window` directly instead.

So the reusable config surface is essentially just `REVDIFF_EXIT_CODE_ON_ANNOTATIONS`; the
rest is runtime state, which is exactly what this skill's script exists to compute.
