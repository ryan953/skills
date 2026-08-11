#!/usr/bin/env bash
# review-window.sh — build and drive the review window: revdiff, the PR
# description, and the review outputs, side by side in one detached tmux window.
#
# Layout — a left column (unchanged: description on top, diff below) and a
# right column that always exists, whatever the author class:
#
#   +---------------------------------+----------------+
#   |  desc   PR description  25%     |  review:<name> |
#   |  (bot / other authors)          +----------------+
#   +---------------------------------+  review:<name> |
#   |                                  +----------------+
#   |  diff   revdiff                 |  idle shell in  |
#   |                                  |  the worktree,  |
#   |                                  |  until a review |
#   |                                  |  pane lands     |
#   +---------------------------------+----------------+
#                65%                        35%
#
# The right column is created at `open` as a single idle pane (a shell cd'd
# into the working tree), so there's always somewhere useful to look even when
# no review skill runs for this class (mine/bot: the agent consumes findings
# itself rather than paning them — see classify.sh's wants_review_panes). The
# first `add-review-pane` call takes that pane over; later calls stack below
# it. A pane can `--follow` a file that's still being written (a `runner=script`
# command mid-run) instead of waiting for it to finish.
#
# Every pane is tagged with a `@lpr_role` user option, so later calls find the
# pane they mean by role instead of by index — indexes shift the moment a pane is
# added or closed, and the iterate loop does both. The right column's idle
# placeholder is tagged `reviews_idle`; once a review lands there its role
# becomes `review:<label>` like any other review pane.
#
# Detached (-d) throughout: opening a review must never yank the terminal away
# from what the user was doing. They switch with Ctrl-b w on their own schedule.
#
# Subcommands:
#   open   --state <f> [--desc <md>] [--cache-dir <d>] [--title <s>] [-- <revdiff args>...]
#   relaunch --state <f>                  # fresh revdiff in the same pane, new output file
#   add-review-pane --state <f> --file <md> --label <name> [--follow]
#   status --state <f>
#   close  --state <f>

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

CMD="${1:-}"; shift || true
[ -n "$CMD" ] || die "usage: review-window.sh {open|relaunch|add-review-pane|status|close} --state <file> [...]"

STATE="" DESC="" CACHE="" TITLE="" FILE="" LABEL="" START_ITER=1 RANGE_ARG="" FOLLOW=no
RD_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --state) STATE="$2"; shift 2 ;;
        --desc) DESC="$2"; shift 2 ;;
        --cache-dir) CACHE="$2"; shift 2 ;;
        --title) TITLE="$2"; shift 2 ;;
        --iter) START_ITER="$2"; shift 2 ;;
        --range) RANGE_ARG="$2"; shift 2 ;;
        --file) FILE="$2"; shift 2 ;;
        --label) LABEL="$2"; shift 2 ;;
        --follow) FOLLOW=yes; shift ;;
        --) shift; RD_ARGS=("$@"); break ;;
        *) RD_ARGS+=("$1"); shift ;;
    esac
done
[ -n "$STATE" ] || die "--state <file> is required"

tm() { tmux -S "$SOCKET" "$@"; }

# Find a pane in this window by its @lpr_role tag. Roles survive splits and
# closes; pane indexes do not.
pane_by_role() {
    tm list-panes -t "$WID" -F '#{pane_id} #{@lpr_role}' 2>/dev/null \
        | awk -v r="$1" '$2==r {print $1; exit}'
}

window_alive() { [ -n "${WID:-}" ] && tm list-panes -t "$WID" >/dev/null 2>&1; }

# The revdiff command for a pane. REVDIFF_EXIT_CODE_ON_ANNOTATIONS makes exit 10
# mean "annotations were written"; the trailing redirect drops the real exit code
# into $DONE the instant revdiff quits, which is what callers Monitor for.
revdiff_cmd() {
    local out="$1" done_file="$2"; shift 2
    local c a
    c="REVDIFF_EXIT_CODE_ON_ANNOTATIONS=true $(sq "$REVDIFF_BIN") $(sq "--output=$out")"
    for a in "$@"; do c="$c $(sq "$a")"; done
    printf '%s; printf %s > %s\n' "$c" '"$?"' "$(sq "$done_file")"
}

new_out_paths() {   # sets OUT/DONE for iteration $1 under $WORK_DIR
    OUT="$WORK_DIR/annotations-$1.txt"
    DONE="$OUT.done"
    rm -f "$OUT" "$DONE"
}

# A review pane pointed at a file that's still being written: wait for the
# first bytes, then follow. `tail -f` on macOS (BSD tail) errors out on a file
# that doesn't exist yet, unlike GNU's `--retry`, so wait for it ourselves.
follow_cmd() {
    local f="$1"
    printf 'echo "waiting for %s ..."; while [ ! -s %s ]; do sleep 0.3; done; tail -f -n +1 %s' \
        "$f" "$(sq "$f")" "$(sq "$f")"
}

case "$CMD" in
open)
    REVDIFF_BIN="$(command -v revdiff 2>/dev/null || true)"
    [ -n "$REVDIFF_BIN" ] || die "revdiff not found in PATH (brew install umputun/apps/revdiff)"
    SOCKET="$(find_tmux_socket)" || die "no running tmux server (start one with: tmux new-session -d)"

    WORK_DIR="${CACHE:-$(job_tmp)}"
    mkdir -p "$WORK_DIR"

    # Reuse the diff skill's range detection rather than reimplementing fork-point
    # resolution here; degrade to plain revdiff args if it isn't installed.
    #
    # --range means the caller already ran detection and is handing back its
    # result (this is how `relaunch` rebuilds a closed window). Detection is not
    # idempotent — it emits flags like --untracked alongside the ref, and feeding
    # two args back in reads as an explicit two-ref historical diff — so resolved
    # args must never be re-detected.
    RANGE="$RANGE_ARG"
    DETECT=""
    [ -z "$RANGE" ] && DETECT="$(find_sibling_script diff detect-range.sh || true)"
    if [ -n "$DETECT" ]; then
        DETECTED=()
        while IFS=$'\t' read -r kind val; do
            case "$kind" in
                range) RANGE="$val" ;;
                arg)   DETECTED+=("$val") ;;
            esac
        done < <(bash "$DETECT" ${RD_ARGS[0]+"${RD_ARGS[@]}"})
        RD_ARGS=(${DETECTED[0]+"${DETECTED[@]}"})
    fi
    [ -n "$RANGE" ] || RANGE="${RD_ARGS[*]:-working tree}"

    ITER="$START_ITER"
    new_out_paths "$ITER"

    WINNAME="${TITLE:-review: ${PWD##*/}}"
    WID="$(tm new-window -d -P -F '#{window_id}' -c "$PWD" -n "$WINNAME" \
        -- sh -c "$(revdiff_cmd "$OUT" "$DONE" ${RD_ARGS[0]+"${RD_ARGS[@]}"})")"
    WINDOW="$(tm list-windows -a -F '#{window_id}|#{session_name}:#{window_index}' \
        | awk -F'|' -v w="$WID" '$1==w {print $2; exit}')"

    DIFF_PANE="$(tm list-panes -t "$WID" -F '#{pane_id}' | head -1)"
    tm set-option -p -t "$DIFF_PANE" @lpr_role diff
    tm select-pane -t "$DIFF_PANE" -T "diff [$RANGE]" 2>/dev/null || true
    # Pane labels are only useful if the border shows them.
    tm set-option -w -t "$WID" pane-border-status top 2>/dev/null || true
    tm set-option -w -t "$WID" pane-border-format ' #{@lpr_role} #{pane_title} ' 2>/dev/null || true

    # The right column, spanning the full window height — split off the diff
    # pane before it gets split again for the description, so the column runs
    # alongside both. Starts as an idle shell in the working tree; the first
    # add-review-pane call takes it over.
    REVIEWS_PANE_ID="$(tm split-window -d -h -l 35% -t "$DIFF_PANE" -P -F '#{pane_id}' \
        -c "$PWD" -- "${SHELL:-/bin/sh}")"
    tm set-option -p -t "$REVIEWS_PANE_ID" @lpr_role reviews_idle
    tm select-pane -t "$REVIEWS_PANE_ID" -T "reviews (idle) — ${PWD##*/}" 2>/dev/null || true

    # The description goes above the diff, not beside it: it's read once for
    # intent, while the diff is scrolled for the whole session.
    DESC_PANE_ID=""
    if [ -n "$DESC" ] && [ -s "$DESC" ]; then
        DESC_PANE_ID="$(tm split-window -d -v -b -l 25% -t "$DIFF_PANE" -P -F '#{pane_id}' \
            -c "$PWD" -- sh -c "$(md_pager_cmd) $(sq "$DESC")")"
        tm set-option -p -t "$DESC_PANE_ID" @lpr_role desc
        tm select-pane -t "$DESC_PANE_ID" -T "PR description" 2>/dev/null || true
    fi

    # Append, never truncate. `relaunch` re-execs `open` when the user closed the
    # window, and the state file by then also holds the context keys start.sh
    # appended (AUTHOR_CLASS, ROUTE, PR_NUMBER, ...) that Steps 5 and 7 read.
    # Truncating here would silently drop them. Every key written below is a
    # state_set, which replaces in place, so nothing stale survives anyway.
    mkdir -p "$(dirname "$STATE")"
    state_set "$STATE" SOCKET       "$SOCKET"
    state_set "$STATE" WID          "$WID"
    state_set "$STATE" WINDOW       "$WINDOW"
    state_set "$STATE" DIFF_PANE    "$DIFF_PANE"
    state_set "$STATE" DESC_PANE_ID "$DESC_PANE_ID"
    state_set "$STATE" REVIEWS_PANE_ID "$REVIEWS_PANE_ID"
    state_set "$STATE" WORK_DIR     "$WORK_DIR"
    state_set "$STATE" RANGE        "$RANGE"
    state_set "$STATE" ITER         "$ITER"
    state_set "$STATE" OUT          "$OUT"
    state_set "$STATE" DONE         "$DONE"
    # Store the revdiff argv pre-quoted so `relaunch` can rebuild the array with
    # `eval` — re-splitting a space-joined string would mangle any arg with a space.
    RD_QUOTED=""
    for a in ${RD_ARGS[0]+"${RD_ARGS[@]}"}; do RD_QUOTED="$RD_QUOTED $(sq "$a")"; done
    state_set "$STATE" RD_ARGS      "${RD_QUOTED# }"
    # Stored so a rebuild reuses the original title (which names the PR and the
    # author class) instead of falling back to a generic one.
    state_set "$STATE" WINNAME      "$WINNAME"
    state_set "$STATE" DESC_MD      "$DESC"

    emit SOCKET "$SOCKET"; emit WID "$WID"; emit WINDOW "$WINDOW"
    emit OUT "$OUT"; emit DONE "$DONE"; emit RANGE "$RANGE"; emit ITER "$ITER"
    emit DESC_PANE_ID "$DESC_PANE_ID"; emit REVIEWS_PANE_ID "$REVIEWS_PANE_ID"
    ;;

relaunch)
    state_load "$STATE" || die "no state at $STATE — run 'open' first"
    SOCKET="${SOCKET:?}"
    REVDIFF_BIN="$(command -v revdiff)"
    eval "RD=(${RD_ARGS:-})"

    ITER=$(( ${ITER:-1} + 1 ))
    new_out_paths "$ITER"

    # respawn-pane -k reuses the existing pane, so the window keeps its identity,
    # its position in the window list, and the description/review panes beside it.
    # Only if the whole window is gone (user closed it) do we rebuild.
    if window_alive && [ -n "$(pane_by_role diff)" ]; then
        DIFF_PANE="$(pane_by_role diff)"
        tm respawn-pane -k -t "$DIFF_PANE" -c "$PWD" \
            -- sh -c "$(revdiff_cmd "$OUT" "$DONE" ${RD[0]+"${RD[@]}"})"
        tm set-option -p -t "$DIFF_PANE" @lpr_role diff
        tm select-pane -t "$DIFF_PANE" -T "diff [$RANGE] #$ITER" 2>/dev/null || true
        state_set "$STATE" ITER "$ITER"
        state_set "$STATE" OUT "$OUT"
        state_set "$STATE" DONE "$DONE"
        emit REBUILT no
    else
        # Rebuild with what `open` actually used last time — the same desc file,
        # title and iteration number — so a window the user closed comes back
        # identical instead of degrading to a generic one that reuses iteration
        # 1's annotation paths.
        exec "$HERE/review-window.sh" open --state "$STATE" \
            ${DESC_MD:+--desc "$DESC_MD"} --cache-dir "${WORK_DIR:-}" \
            --iter "$ITER" ${WINNAME:+--title "$WINNAME"} \
            ${RANGE:+--range "$RANGE"} -- ${RD[0]+"${RD[@]}"}
    fi
    emit SOCKET "$SOCKET"; emit WID "$WID"; emit WINDOW "${WINDOW:-}"
    emit OUT "$OUT"; emit DONE "$DONE"; emit ITER "$ITER"
    ;;

add-review-pane)
    state_load "$STATE" || die "no state at $STATE — run 'open' first"
    SOCKET="${SOCKET:?}"
    [ -n "$FILE" ] || die "--file is required"
    if [ "$FOLLOW" = no ]; then
        [ -s "$FILE" ] || die "--file must point at a non-empty markdown file (pass --follow to watch one that's still being written)"
    fi
    LABEL="${LABEL:-review}"
    window_alive || die "review window $WID is gone; reopen it first"

    if [ "$FOLLOW" = yes ]; then
        CONTENT_CMD="$(follow_cmd "$FILE")"
    else
        CONTENT_CMD="$(md_pager_cmd) $(sq "$FILE")"
    fi

    # Roles, not stored state, are the source of truth for what's already in
    # the column — they survive a pane the user closed by hand, where a
    # remembered id wouldn't. First review pane takes over the idle
    # placeholder that already spans the column; later ones stack below the
    # last one so the diff never gets narrower than one split's worth.
    LAST="$(tm list-panes -t "$WID" -F '#{pane_id} #{@lpr_role}' \
        | awk '$2 ~ /^review:/ {p=$1} END{print p}')"
    IDLE="$(pane_by_role reviews_idle)"
    if [ -n "$LAST" ]; then
        PID="$(tm split-window -d -v -l 50% -t "$LAST" -P -F '#{pane_id}' \
            -c "$PWD" -- sh -c "$CONTENT_CMD")"
    elif [ -n "$IDLE" ]; then
        PID="$IDLE"
        tm respawn-pane -k -t "$PID" -c "$PWD" -- sh -c "$CONTENT_CMD"
    else
        # No idle placeholder — state from before it existed, or it was
        # closed by hand. Fall back to carving a column out of the diff pane.
        PID="$(tm split-window -d -h -l 35% -t "$(pane_by_role diff)" -P -F '#{pane_id}' \
            -c "$PWD" -- sh -c "$CONTENT_CMD")"
    fi
    tm set-option -p -t "$PID" @lpr_role "review:$LABEL"
    tm select-pane -t "$PID" -T "$LABEL" 2>/dev/null || true
    emit PANE "$PID"; emit LABEL "$LABEL"
    ;;

status)
    state_load "$STATE" || die "no state at $STATE"
    SOCKET="${SOCKET:?}"
    if window_alive; then
        printf 'window %s (%s) — range: %s — iteration %s\n' \
            "$WID" "${WINDOW:-?}" "${RANGE:-?}" "${ITER:-1}"
        tm list-panes -t "$WID" -F '  #{pane_id} #{@lpr_role} #{?pane_dead,dead,live}'
    else
        printf 'window %s is gone\n' "${WID:-?}"
    fi
    if [ -f "${DONE:-/nonexistent}" ]; then
        printf 'revdiff exited (%s); annotations: %s\n' "$(cat "$DONE")" \
            "$([ -s "${OUT:-}" ] && wc -l < "$OUT" | tr -d ' ' || echo 0) line(s)"
    else
        printf 'revdiff still open\n'
    fi
    ;;

close)
    state_load "$STATE" || die "no state at $STATE"
    SOCKET="${SOCKET:?}"
    window_alive && tm kill-window -t "$WID" || true
    emit CLOSED "${WID:-}"
    ;;

*) die "unknown subcommand: $CMD" ;;
esac
