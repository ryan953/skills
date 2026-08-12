#!/usr/bin/env bash
# sync-check.sh — is this branch behind its base, or already conflicted with it,
# before anyone opens a diff on it.
#
# Runs right after checkout.sh, from inside the worktree, and before the diff is
# measured or the window opens: what this script does to the tree changes both,
# so it has to happen first, not get discovered mid-review.
#
# GitHub's own merge state is the source of truth for a PR — mergeStateStatus
# BEHIND means stale, DIRTY means conflicts — because that's what the human
# sees on the PR page; acting on anything else would disagree with what they'd
# find if they looked. A branch with no PR has no such status, so it's computed
# locally: commits on the base that aren't in the branch. A branch that isn't
# behind at all can't conflict with an unmoved base, so no local merge-tree
# probe is needed for that case.
#
# `sync_action` (classify.sh) turns (class, stale, conflicts, approved) into
# one of three things to do, and this script is the only one of the three that
# mutates anything:
#   merge-master — fetch the base and merge it in. A clean merge is pushed
#     immediately (only when the branch was already public — never turns an
#     unpushed branch public as a side effect). A conflicted merge is left
#     exactly as `git merge` left it: conflict markers in the tree, nothing
#     committed, nothing pushed — the caller resolves it as the first item of
#     work, same as any other apply-route edit.
#   notify — someone else's branch. Nothing is touched; the facts are emitted
#     so the caller can tell the user in chat.
#   none — nothing to do.
#
# Usage:
#   sync-check.sh --class <mine|bot|other> --has-pr <yes|no> --pushed <yes|no> \
#       --head <branch> [--base <branch>] [--pr <n>] [--repo <owner/name>]
#
# Output: eval-safe KEY='value' lines — see EMITTED KEYS at the bottom.
# Run from inside the worktree under review.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
# shellcheck source=classify.sh
. "$HERE/classify.sh"

CLASS="" HAS_PR="" PUSHED="" HEAD_BRANCH="" BASE="" PR="" REPO_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --class) CLASS="$2"; shift 2 ;;
        --has-pr) HAS_PR="$2"; shift 2 ;;
        --pushed) PUSHED="$2"; shift 2 ;;
        --head) HEAD_BRANCH="$2"; shift 2 ;;
        --base) BASE="$2"; shift 2 ;;
        --pr) PR="$2"; shift 2 ;;
        --repo) REPO_ARGS=(--repo "$2"); shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done
[ -n "$CLASS" ]       || die "--class is required"
[ -n "$HAS_PR" ]      || die "--has-pr is required"
[ -n "$PUSHED" ]      || die "--pushed is required"
[ -n "$HEAD_BRANCH" ] || die "--head is required"

git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"

MERGE_STATE=n/a
REVIEW_DECISION=""

if [ "$HAS_PR" = yes ]; then
    [ -n "$PR" ]   || die "--pr is required when --has-pr yes"
    [ -n "$BASE" ] || die "--base is required when --has-pr yes"

    # mergeStateStatus is computed asynchronously right after a push; a short
    # bounded poll covers the common case instead of reporting a stale UNKNOWN.
    # Both bounds are overridable so tests (and an impatient caller) don't have
    # to eat the real wait.
    POLL_TRIES="${LPR_SYNC_POLL_TRIES:-5}"
    POLL_SLEEP="${LPR_SYNC_POLL_SLEEP:-1}"
    PR_JSON="{}"
    tries=0
    while :; do
        PR_JSON="$(gh pr view "$PR" "${REPO_ARGS[@]}" \
            --json mergeStateStatus,reviewDecision 2>/dev/null || echo '{}')"
        MERGE_STATE="$(printf '%s' "$PR_JSON" | jq -r '.mergeStateStatus // "UNKNOWN"')"
        [ "$MERGE_STATE" != UNKNOWN ] && break
        tries=$((tries + 1))
        [ "$tries" -ge "$POLL_TRIES" ] && break
        sleep "$POLL_SLEEP"
    done
    REVIEW_DECISION="$(printf '%s' "$PR_JSON" | jq -r '.reviewDecision // empty')"
else
    # No PR: no mergeStateStatus to read, so figure out a base and compute it
    # locally. BASE is always `mine` here (pr-context.sh's rule), so getting
    # this wrong costs a skipped sync check, not a misrouted one.
    BASE="${BASE:-$(default_branch)}"
    git fetch origin "$BASE" --quiet 2>/dev/null || true
    if git rev-parse --verify --quiet "origin/$BASE^{commit}" >/dev/null 2>&1; then
        BEHIND="$(git rev-list --count "HEAD..origin/$BASE" 2>/dev/null || echo 0)"
        if [ "${BEHIND:-0}" -gt 0 ]; then MERGE_STATE=BEHIND; else MERGE_STATE=CLEAN; fi
    fi
fi

STALE=no;      [ "$MERGE_STATE" = BEHIND ]   && STALE=yes
CONFLICTS=no;  [ "$MERGE_STATE" = DIRTY ]    && CONFLICTS=yes
APPROVED=no;   [ "$REVIEW_DECISION" = APPROVED ] && APPROVED=yes

ACTION="$(sync_action "$CLASS" "$STALE" "$CONFLICTS" "$APPROVED")"

MERGE_RESULT=skipped
CONFLICT_FILES=""
JUST_PUSHED=no
NOTE=""

if [ "$ACTION" = merge-master ] && [ "$MERGE_STATE" != n/a ]; then
    git fetch origin "$BASE" --quiet 2>/dev/null || true
    if MERGE_OUT="$(git merge --no-edit "origin/$BASE" 2>&1)"; then
        MERGE_RESULT=clean
        # Only push a branch that was already public — never the first push of
        # one the caller hadn't chosen to share yet.
        if [ "$HAS_PR" = yes ] || [ "$PUSHED" = yes ]; then
            if git push origin "HEAD:$HEAD_BRANCH" --quiet 2>/dev/null; then
                JUST_PUSHED=yes
            else
                NOTE="merged cleanly but the push failed; push manually"
            fi
        fi
    else
        CONFLICT_FILES="$(git diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ' ')"
        if [ -n "$CONFLICT_FILES" ]; then
            MERGE_RESULT=conflict
        else
            # `git merge` failed for a reason other than a content conflict —
            # a dirty working tree, most likely. Nothing to resolve by editing;
            # say so rather than sending the caller looking for conflict markers
            # that don't exist.
            MERGE_RESULT=blocked
            NOTE="$(printf '%s\n' "$MERGE_OUT" | head -1)"
        fi
    fi
fi

emit MERGE_STATE     "$MERGE_STATE"
emit STALE           "$STALE"
emit CONFLICTS       "$CONFLICTS"
emit REVIEW_DECISION "$REVIEW_DECISION"
emit APPROVED        "$APPROVED"
emit SYNC_BASE       "$BASE"
emit SYNC_ACTION     "$ACTION"
emit MERGE_RESULT    "$MERGE_RESULT"
emit CONFLICT_FILES  "$CONFLICT_FILES"
emit JUST_PUSHED     "$JUST_PUSHED"
emit SYNC_NOTE       "$NOTE"

# EMITTED KEYS
#   MERGE_STATE     BEHIND | DIRTY | CLEAN | n/a — n/a when there's nothing to
#                   compare against (no PR and no resolvable base)
#   STALE           yes | no  — MERGE_STATE = BEHIND
#   CONFLICTS       yes | no  — MERGE_STATE = DIRTY
#   REVIEW_DECISION APPROVED | CHANGES_REQUESTED | REVIEW_REQUIRED | '' (no PR)
#   APPROVED        yes | no  — REVIEW_DECISION = APPROVED
#   SYNC_BASE       the base branch compared against
#   SYNC_ACTION     merge-master | notify | none  (classify.sh: sync_action)
#   MERGE_RESULT    clean | conflict | blocked | skipped
#   CONFLICT_FILES  space-separated paths still unmerged, when MERGE_RESULT=conflict
#   JUST_PUSHED     yes | no  — a clean merge was pushed by this run
#   SYNC_NOTE       one line of context for a failed push or a non-conflict block
