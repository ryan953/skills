#!/usr/bin/env bash
# diff.sh — detect an implied diff range and open revdiff in a persistent tmux window.
#
# Why a tmux *window* and not the stock revdiff launcher: in a headless / background
# agent shell there is no $TMUX and no controlling TTY, so revdiff's own launcher prints
# "no overlay terminal available" and dies. A window created directly against the running
# tmux server needs neither — it survives client disconnects, never steals focus (-d), and
# the user switches to it on their own schedule (Ctrl-b <n> / Ctrl-b w).
#
# Usage:
#   diff.sh                 # implied range (see detection below)
#   diff.sh <base>          # diff <base> against the working tree
#   diff.sh <base> <against># explicit two-ref diff
#   diff.sh <path>          # single-file context review (--only)
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
# Range detection lives in detect-range.sh (git-only, tmux/revdiff-free) so it
# can be unit-tested in isolation. It prints TAB-separated `range` and `arg`
# records; we collect the args into REVDIFF_ARGS and keep the range summary.
DETECT="${0%/*}/detect-range.sh"
[ -f "$DETECT" ] || { echo "error: detect-range.sh not found next to diff.sh" >&2; exit 1; }

DETECT_OUT="$(bash "$DETECT" "$@")" || exit $?
REVDIFF_ARGS=()
RANGE=""
while IFS=$'\t' read -r kind val; do
    case "$kind" in
        range) RANGE="$val" ;;
        arg)   REVDIFF_ARGS+=("$val") ;;
    esac
done <<< "$DETECT_OUT"

# ---- launch in a background tmux window ------------------------------------
TMPDIR_JOB="${CLAUDE_JOB_DIR:+$CLAUDE_JOB_DIR/tmp}"
TMPDIR_JOB="${TMPDIR_JOB:-${TMPDIR:-/tmp}}"
mkdir -p "$TMPDIR_JOB"
OUT="$(mktemp "$TMPDIR_JOB/diff-output-XXXXXX")"
DONE="$OUT.done"; rm -f "$DONE"

# window name: last path segment of cwd + the range summary
WINNAME="diff: ${PWD##*/} [$RANGE]"

# Build a single-quoted, sh-safe command string for the window.
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
CMD="REVDIFF_EXIT_CODE_ON_ANNOTATIONS=true $(sq "$REVDIFF_BIN") $(sq "--output=$OUT")"
for a in "${REVDIFF_ARGS[@]}"; do CMD="$CMD $(sq "$a")"; done
CMD="$CMD; printf '%s' \"\$?\" > $(sq "$DONE")"

WID="$(tmux -S "$SOCKET" new-window -d -P -F '#{window_id}' -c "$PWD" -n "$WINNAME" -- sh -c "$CMD")"
WINDOW="$(tmux -S "$SOCKET" list-windows -a -F '#{window_id}|#{session_name}:#{window_index}' | grep "^$WID|" | cut -d'|' -f2)"

# Emit eval-safe KEY='value' lines (values hold spaces/parens; caller does `eval "$(diff.sh)"`).
emit() { printf "%s=%s\n" "$1" "$(sq "$2")"; }
emit WID    "$WID"
emit OUT    "$OUT"
emit DONE   "$DONE"
emit WINDOW "$WINDOW"
emit SOCKET "$SOCKET"
emit RANGE  "$RANGE"
