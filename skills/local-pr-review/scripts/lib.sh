#!/usr/bin/env bash
# lib.sh — helpers shared by the local-pr-review scripts. Sourced, never run.
#
# Nothing here talks to the network or mutates review state; the callers do that.
# Kept separate so pr-context.sh / review-window.sh / review-plan.sh /
# post-annotations.sh agree on quoting, tmux socket discovery, state files and
# cache layout instead of each re-deriving them.

# shell-quote one argument for safe embedding in `sh -c` strings and in the
# KEY='value' lines callers `eval`.
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# emit an eval-safe KEY='value' line
emit() { printf "%s=%s\n" "$1" "$(sq "${2-}")"; }

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Resolve the running tmux server socket. Prefers an inherited $TMUX (the socket
# is the part before the first comma); otherwise probes the conventional paths
# for a live server owned by this uid. A background agent shell has no $TMUX, so
# the probe is the normal path, not the fallback.
find_tmux_socket() {
    if [ -n "${TMUX:-}" ]; then
        printf '%s\n' "${TMUX%%,*}"
        return 0
    fi
    local uid d s
    uid="$(id -u)"
    for d in "${TMUX_TMPDIR:-/tmp}" /tmp /private/tmp; do
        s="$d/tmux-$uid/default"
        if [ -S "$s" ] && tmux -S "$s" list-sessions >/dev/null 2>&1; then
            printf '%s\n' "$s"
            return 0
        fi
    done
    return 1
}

# Job-scoped scratch dir. Parallel background jobs share /tmp and clobber each
# other's fixed-name files, so prefer $CLAUDE_JOB_DIR/tmp when the harness set it.
job_tmp() {
    local d="${CLAUDE_JOB_DIR:+$CLAUDE_JOB_DIR/tmp}"
    d="${d:-${TMPDIR:-/tmp}}"
    mkdir -p "$d"
    printf '%s\n' "$d"
}

# Slugify for filenames: lowercase, non-alphanumerics collapsed to single dashes.
slugify() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]\{1,\}/-/g; s/^-//; s/-$//'
}

# Cache root for review outputs and session state. Under ~/.cache (not job tmp)
# on purpose: re-reviewing the same commit in a later session should hit the
# cache, which a job-scoped dir would defeat.
cache_root() {
    printf '%s\n' "${LOCAL_PR_REVIEW_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/local-pr-review}"
}

# cache_dir <repo-slug> <key> — per-commit cache directory, created.
# The key is the head SHA: findings describe *that* tree, so the next push must
# miss the cache rather than resurrect a review of code that no longer exists.
cache_dir() {
    local slug="${1:-unknown}" key="${2:-work}" d
    d="$(cache_root)/$(slugify "$slug")/$(slugify "$key")"
    mkdir -p "$d"
    printf '%s\n' "$d"
}

# "owner/name" for the repo containing $PWD, or empty when there's no remote.
repo_slug() {
    gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true
}

# Best pager for a markdown file, as an argv string. `bat` renders headings and
# code fences and stays open; plain `less -R` is the fallback. Never `cat`: the
# pane would print once and exit, taking the content off screen.
md_pager_cmd() {
    if command -v glow >/dev/null 2>&1; then
        printf 'glow -p'
    elif command -v bat >/dev/null 2>&1; then
        printf 'bat --style=plain --language=md --paging=always'
    else
        printf 'less -R'
    fi
}

# find_sibling_script <skill> <script> — absolute path to another skill's script.
# This skill reuses the `diff` skill's range detection rather than forking it,
# and skills live either installed user-scope or in a repo checkout, so probe
# both. Prints nothing and returns 1 when absent so callers can degrade.
find_sibling_script() {
    local skill="$1" script="$2" c here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # .../local-pr-review/scripts
    for c in "$here/../../$skill/scripts/$script" \
             "$HOME/.claude/skills/$skill/scripts/$script" \
             "$HOME/.agents/skills/$skill/scripts/$script" \
             "$HOME/code/skills/skills/$skill/scripts/$script"; do
        [ -f "$c" ] && { printf '%s\n' "$c"; return 0; }
    done
    return 1
}

# ---- state file -------------------------------------------------------------
# One review session's runtime facts (window id, pane ids, output paths, author
# class) live in a KEY='value' file, so every later call — relaunch, add-pane,
# post, verdict — reads them instead of taking a dozen flags. The format is
# exactly what `eval` consumes, so a caller can also `eval "$(cat $STATE)"`.

state_set() {    # state_set <file> <key> <value> — replace or append one key
    local f="$1" k="$2" v="$3" tmp
    tmp="$(mktemp "${f}.XXXXXX")"
    if [ -f "$f" ]; then grep -v "^$k=" "$f" > "$tmp" || true; fi
    printf '%s=%s\n' "$k" "$(sq "$v")" >> "$tmp"
    mv "$tmp" "$f"
}

state_get() {    # state_get <file> <key> — empty + status 1 when unset
    local f="$1" k="$2" line
    [ -f "$f" ] || return 1
    line="$(grep -m1 "^$k=" "$f")" || return 1
    eval "printf '%s\n' ${line#*=}"
}

state_load() {   # state_load <file> — define every key as a shell variable
    local f="$1"
    [ -f "$f" ] || return 1
    # shellcheck disable=SC1090
    . "$f"
}
