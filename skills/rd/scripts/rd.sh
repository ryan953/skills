#!/usr/bin/env bash
# rd.sh — detect an implied diff range and open revdiff in a persistent tmux window.
#
# Why a tmux *window* and not the stock revdiff launcher: in a headless / background
# agent shell there is no $TMUX and no controlling TTY, so revdiff's own launcher prints
# "no overlay terminal available" and dies. A window created directly against the running
# tmux server needs neither — it survives client disconnects, never steals focus (-d), and
# the user switches to it on their own schedule (Ctrl-b <n> / Ctrl-b w).
#
# Usage:
#   rd.sh                 # implied range (see detection below)
#   rd.sh <base>          # diff <base> against the working tree
#   rd.sh <base> <against># explicit two-ref diff
#   rd.sh <path>          # single-file context review (--only)
#
# Output (stdout, KEY=VALUE lines the caller parses):
#   WID=<tmux window id>
#   OUT=<annotations output file>
#   DONE=<completion sentinel file>
#   WINDOW=<session:index name>
#   RANGE=<human description of what is being diffed>

set -euo pipefail

# ---- resolve revdiff -------------------------------------------------------
REVDIFF_BIN="$(command -v revdiff 2>/dev/null || true)"
if [ -z "$REVDIFF_BIN" ]; then
    echo "error: revdiff not found in PATH (brew install umputun/apps/revdiff)" >&2
    exit 1
fi

# ---- resolve the running tmux server socket --------------------------------
# Prefer an inherited $TMUX (socket is the part before the first comma). Otherwise
# probe the conventional locations for a live server owned by this uid.
find_socket() {
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

if ! SOCKET="$(find_socket)"; then
    echo "error: no running tmux server found (start one with: tmux new-session -d)" >&2
    exit 1
fi

# ---- decide what to diff ---------------------------------------------------
# REVDIFF_ARGS is the argv passed to revdiff; RANGE is a human summary.
REVDIFF_ARGS=()
RANGE=""

is_ref() { git rev-parse --verify --quiet "$1^{commit}" >/dev/null 2>&1; }

main_branch() {
    local rh
    if rh="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null)"; then
        printf '%s\n' "${rh##refs/remotes/origin/}"
    elif git show-ref --verify --quiet refs/heads/master 2>/dev/null; then
        echo master
    else
        echo main
    fi
}

case "$#" in
    0)
        # Implied range. Feature branch (the common case) → the WHOLE branch vs main,
        # no prompting. On main, fall back to working-tree / last-commit like revdiff does.
        MB="$(main_branch)"
        BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
        DIRTY=""
        [ -n "$(git status --porcelain 2>/dev/null)" ] && DIRTY=1
        if [ "$BRANCH" = "$MB" ]; then
            if [ -n "$DIRTY" ]; then
                REVDIFF_ARGS=()                       # uncommitted changes
                RANGE="working tree (uncommitted on $MB)"
            else
                REVDIFF_ARGS=(HEAD~1)                 # last commit
                RANGE="HEAD~1..HEAD (last commit on $MB)"
            fi
        else
            # full branch: merge-base of main..HEAD, including any uncommitted work
            BASE="$(git merge-base "$MB" HEAD 2>/dev/null || echo "$MB")"
            REVDIFF_ARGS=("$BASE")
            if [ -n "$DIRTY" ]; then
                RANGE="$MB..$BRANCH branch diff + uncommitted (base $BASE)"
            else
                RANGE="$MB..$BRANCH full branch diff (base $BASE)"
            fi
        fi
        ;;
    1)
        ARG="$1"
        if [ -f "$ARG" ] || { [ ! -e "$ARG" ] && ! is_ref "$ARG" && printf '%s' "$ARG" | grep -q '[/.]'; }; then
            REVDIFF_ARGS=(--only="$ARG")
            RANGE="single file: $ARG"
        else
            REVDIFF_ARGS=("$ARG")
            RANGE="$ARG..working tree"
        fi
        ;;
    2)
        REVDIFF_ARGS=("$1" "$2")
        RANGE="$1..$2"
        ;;
    *)
        echo "error: expected 0, 1, or 2 arguments, got $#" >&2
        exit 1
        ;;
esac

# ---- launch in a background tmux window ------------------------------------
TMPDIR_JOB="${CLAUDE_JOB_DIR:+$CLAUDE_JOB_DIR/tmp}"
TMPDIR_JOB="${TMPDIR_JOB:-${TMPDIR:-/tmp}}"
mkdir -p "$TMPDIR_JOB"
OUT="$(mktemp "$TMPDIR_JOB/rd-output-XXXXXX")"
DONE="$OUT.done"; rm -f "$DONE"

# window name: last path segment of cwd + the range summary
WINNAME="rd: ${PWD##*/} [$RANGE]"

# Build a single-quoted, sh-safe command string for the window.
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
CMD="REVDIFF_EXIT_CODE_ON_ANNOTATIONS=true $(sq "$REVDIFF_BIN") $(sq "--output=$OUT")"
for a in "${REVDIFF_ARGS[@]}"; do CMD="$CMD $(sq "$a")"; done
CMD="$CMD; printf '%s' \"\$?\" > $(sq "$DONE")"

WID="$(tmux -S "$SOCKET" new-window -d -P -F '#{window_id}' -c "$PWD" -n "$WINNAME" -- sh -c "$CMD")"
WINDOW="$(tmux -S "$SOCKET" list-windows -a -F '#{window_id}|#{session_name}:#{window_index}' | grep "^$WID|" | cut -d'|' -f2)"

# Emit eval-safe KEY='value' lines (values hold spaces/parens; caller does `eval "$(rd.sh)"`).
emit() { printf "%s=%s\n" "$1" "$(sq "$2")"; }
emit WID    "$WID"
emit OUT    "$OUT"
emit DONE   "$DONE"
emit WINDOW "$WINDOW"
emit SOCKET "$SOCKET"
emit RANGE  "$RANGE"
