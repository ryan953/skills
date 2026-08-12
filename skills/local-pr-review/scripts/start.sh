#!/usr/bin/env bash
# start.sh — everything that can be decided without a model, in one call.
#
# Resolves the target, classifies the author, gets the code on disk, measures the
# diff, and opens the review window. What's left for the model afterwards is the
# part that actually needs judgement: pick a complexity tier from the facts, run
# the planned skills, and route the annotations.
#
# One call instead of six also means one consistent set of facts: the same head
# SHA drives the cache dir, the diff base, the description pane and the window
# title, so nothing can drift between steps.
#
# Usage:
#   start.sh [<pr-url|pr-number|branch>] [--repo owner/name] [--no-window]
#
# Output: the union of pr-context.sh, complexity-facts.sh and review-window.sh
# keys, plus WORKTREE and MODE. Every one of them is also written to $STATE, so
# later calls take --state instead of a dozen flags.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

TARGET="" REPO_ARGS=() OPEN_WINDOW=yes
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) REPO_ARGS=(--repo "$2"); shift 2 ;;
        --no-window) OPEN_WINDOW=no; shift ;;
        -*) die "unknown flag: $1" ;;
        *) TARGET="$1"; shift ;;
    esac
done

# ---- 1. what is this, and who wrote it -------------------------------------
CTX="$(bash "$HERE/pr-context.sh" ${TARGET:+"$TARGET"} ${REPO_ARGS[0]+"${REPO_ARGS[@]}"})"
eval "$CTX"

# A merged or closed PR has nothing to review into: stop here rather than opening
# a window over a diff whose outcome is already decided.
case "${PR_STATE:-}" in
    MERGED|CLOSED)
        printf '%s\n' "$CTX"
        emit STOP "PR #$PR_NUMBER is $PR_STATE — nothing to review"
        exit 0
        ;;
esac

# ---- 2. get it on disk ------------------------------------------------------
eval "$(bash "$HERE/checkout.sh" --ref "$HEAD_REF" ${PR_NUMBER:+--pr "$PR_NUMBER"})"
cd "$WORKTREE"

# ---- 2.5 sync with the base branch, before anything measures or opens ------
# A merge here changes the tree the diff is about to measure and the window is
# about to open on, so it has to happen first, not get discovered mid-review.
SYNC_OUT="$(bash "$HERE/sync-check.sh" --class "$AUTHOR_CLASS" --has-pr "$HAS_PR" \
    --pushed "$PUSHED" --head "$HEAD_REF" ${BASE_REF:+--base "$BASE_REF"} \
    ${PR_NUMBER:+--pr "$PR_NUMBER"} ${REPO:+--repo "$REPO"})"
eval "$SYNC_OUT"

# A conflicted (or otherwise blocked) merge is left exactly as `git merge` left
# it — conflict markers in the tree, nothing committed, nothing pushed — so
# there's nothing sane to diff or open a window on yet.
case "${MERGE_RESULT:-skipped}" in
    conflict|blocked)
        printf '%s\n' "$CTX"
        printf '%s\n' "$SYNC_OUT"
        emit BLOCKED "sync with $SYNC_BASE left the branch $MERGE_RESULT — resolve, commit, push, then re-run start.sh to continue"
        exit 0
        ;;
esac

# ---- 3. measure the diff ----------------------------------------------------
# --base origin/<base> for a PR: the facts should cover what the PR proposes to
# merge, not whatever the local trunk copy happens to be at.
BASE_ARGS=()
if [ -n "${BASE_REF:-}" ] && git rev-parse --verify --quiet "origin/$BASE_REF^{commit}" >/dev/null 2>&1; then
    BASE_ARGS=(--base "origin/$BASE_REF")
fi
FACTS_OUT="$(bash "$HERE/complexity-facts.sh" --cache-dir "$CACHE_DIR" ${BASE_ARGS[0]+"${BASE_ARGS[@]}"})"
eval "$FACTS_OUT"

# ---- 4. open the window ----------------------------------------------------
WIN_OUT=""
if [ "$OPEN_WINDOW" = yes ]; then
    DESC_ARGS=()
    [ "$DESC_PANE" = yes ] && [ -n "$DESC_FILE" ] && DESC_ARGS=(--desc "$DESC_FILE")
    if [ "$HAS_PR" = yes ]; then
        TITLE="review #$PR_NUMBER ($AUTHOR_CLASS): $PR_TITLE"
    else
        TITLE="review $HEAD_REF (local)"
    fi
    WIN_OUT="$(bash "$HERE/review-window.sh" open --state "$STATE" \
        --cache-dir "$CACHE_DIR" --title "$TITLE" \
        ${DESC_ARGS[0]+"${DESC_ARGS[@]}"} -- "$BASE")"
    eval "$WIN_OUT"
fi

# ---- 5. persist the context alongside the window state ---------------------
# review-window.sh created $STATE, so these are appended after it: every later
# script reads one file and needs no flags.
while IFS='=' read -r k v; do
    [ -n "$k" ] || continue
    eval "state_set \"\$STATE\" \"\$k\" $v"
done <<EOF
$CTX
$SYNC_OUT
$FACTS_OUT
$(emit WORKTREE "$WORKTREE"; emit MODE "$MODE")
EOF

printf '%s\n' "$CTX"
printf '%s\n' "$SYNC_OUT"
printf '%s\n' "$FACTS_OUT"
emit WORKTREE "$WORKTREE"
emit MODE     "$MODE"
[ -n "$WIN_OUT" ] && printf '%s\n' "$WIN_OUT"
emit NEXT "read \$FACTS -> pick a tier -> review-plan.sh --tier <t> --class $AUTHOR_CLASS --frontend $FRONTEND --cache-dir $(sq "$CACHE_DIR")"
