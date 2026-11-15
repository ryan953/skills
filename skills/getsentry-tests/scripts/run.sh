#!/usr/bin/env bash
# run.sh — read a sentry PR's facts, or add the getsentry tests label to it.
#
# Usage:
#   run.sh facts [<pr>] [--rerun]
#   run.sh apply [<pr>] --expected-head <sha> [--rerun] [--dry-run]
#
# `facts` changes nothing and prints eval-safe KEY='value' lines, NEXT among
# them. `apply` re-reads the facts, refuses if the head moved since they were
# shown, then adds the label (taking it off first with --rerun).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

MODE="${1:-}"; shift || true
case "$MODE" in facts|apply) ;; *) die "usage: run.sh facts|apply [<pr>] [--rerun]" ;; esac

TARGET="" EXPECTED_HEAD="" RERUN=no DRY=no
while [ $# -gt 0 ]; do
    case "$1" in
        --rerun) RERUN=yes; shift ;;
        --expected-head) EXPECTED_HEAD="$2"; shift 2 ;;
        --dry-run) DRY=yes; shift ;;
        -*) die "unknown flag: $1" ;;
        *) TARGET="$1"; shift ;;
    esac
done

command -v gh >/dev/null 2>&1 || die "gh (GitHub CLI) not found on PATH"

PARSED="$(parse_target "$TARGET")"
if [ -z "$PARSED" ]; then
    URL="$(gh pr view ${TARGET:+"$TARGET"} --json url -q .url)" \
        || die "no PR found for '${TARGET:-current branch}'"
    PARSED="$(parse_target "$URL")"
fi
read -r OWNER NAME NUMBER <<<"$PARSED"
REPO="$OWNER/$NAME"

INFO="$(gh pr view "$NUMBER" --repo "$REPO" \
    --json number,title,url,state,headRefOid,isCrossRepository,author,labels)" \
    || die "could not load $REPO#$NUMBER"
j() { printf '%s' "$INFO" | jq -r "$1"; }
STATE="$(j .state)"
HEAD_SHA="$(j .headRefOid)"
IS_FORK="$(j .isCrossRepository)"
HAS_LABEL="$(printf '%s' "$INFO" | jq -r --arg l "$TEST_LABEL" \
    'if (.labels | map(.name) | index($l)) then "yes" else "no" end')"
NEXT="$(next_step "$REPO" "$STATE" "$HAS_LABEL" "$IS_FORK" "$RERUN")"

if [ "$MODE" = facts ]; then
    emit REPO        "$REPO"
    emit PR_NUMBER   "$NUMBER"
    emit PR_TITLE    "$(j .title)"
    emit PR_URL      "$(j .url)"
    emit AUTHOR      "$(j .author.login)"
    emit HEAD_SHA    "$HEAD_SHA"
    emit IS_FORK     "$IS_FORK"
    emit HAS_LABEL   "$HAS_LABEL"
    emit TEST_LABEL  "$TEST_LABEL"
    emit RERUN       "$RERUN"
    emit NEXT        "$NEXT"
    emit STOP_REASON "$(stop_reason "$REPO" "$STATE" "$HAS_LABEL" "$RERUN")"
    exit 0
fi

[ "$NEXT" = stop ] && die "$(stop_reason "$REPO" "$STATE" "$HAS_LABEL" "$RERUN")"
[ -n "$EXPECTED_HEAD" ] || die "--expected-head is required"
case "$HEAD_SHA" in
    "$EXPECTED_HEAD"*) ;;
    *) die "PR head moved from ${EXPECTED_HEAD} to ${HEAD_SHA:0:8}; run /getsentry-tests again." ;;
esac

run() {
    if [ "$DRY" = yes ]; then
        local a out=""; for a in "$@"; do out="$out $(sq "$a")"; done
        printf 'would run:%s\n' "$out" >&2
    else
        "$@" >&2
    fi
}

REMOVED=no
if [ "$HAS_LABEL" = yes ]; then
    run gh pr edit "$NUMBER" --repo "$REPO" --remove-label "$TEST_LABEL"
    REMOVED=yes
fi
run gh pr edit "$NUMBER" --repo "$REPO" --add-label "$TEST_LABEL"

emit LABEL_ADDED "$([ "$DRY" = yes ] && printf would || printf yes)"
emit RELABELLED  "$REMOVED"
emit PR_URL      "$(j .url)"
