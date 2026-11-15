#!/usr/bin/env bash
# apply.sh — merge a PR now, or turn on automerge, pinned to the head the user saw.
#
# Usage:
#   apply.sh [<pr>] [--repo owner/name] --merge now|auto \
#            --expected-head <sha> [--dry-run]
#
# If the PR moved since the question (a push or rebase), nothing is done: the
# user would be merging code they never saw. Never passes --admin: a PR that
# GitHub blocks stays blocked.
#
# Output: eval-safe KEY='value' lines:
#   RESULT   merged | auto-enabled | auto-already | would | failed
#   ERROR    gh's error text when RESULT=failed
#   PR_URL
# Exits 1 when RESULT=failed, after printing the keys.

# PR_NUMBER and the other upper-case facts are set by eval'ing pr-facts.sh.
# shellcheck disable=SC2153

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

FACT_ARGS=()
MERGE=""
EXPECTED_HEAD=""
DRY=no
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) FACT_ARGS+=(--repo "$2"); shift 2 ;;
        --expected-head) EXPECTED_HEAD="$2"; shift 2 ;;
        --merge) MERGE="$2"; shift 2 ;;
        --dry-run) DRY=yes; shift ;;
        -*) die "unknown flag: $1" ;;
        *) FACT_ARGS+=("$1"); shift ;;
    esac
done
case "$MERGE" in now|auto) ;; *) die "--merge must be now or auto" ;; esac
[ -n "$EXPECTED_HEAD" ] || die "--expected-head is required"

FACTS="$("$HERE/pr-facts.sh" ${FACT_ARGS[0]+"${FACT_ARGS[@]}"})" || exit 1
eval "$FACTS"
[ "$NEXT" = stop ] && die "$STOP_REASON"
case "$HEAD_SHA" in
    "$EXPECTED_HEAD"*) ;;
    *) die "PR head moved from ${EXPECTED_HEAD} to ${HEAD_SHA:0:8} since the question was asked; run /merge-pr again." ;;
esac
[ -n "$MERGE_METHOD" ] || die "$REPO allows no merge method."

RESULT="" ERROR=""
if [ "$MERGE" = auto ] && [ "$AUTO_MERGE_ON" = yes ]; then
    RESULT=auto-already
else
    [ "$MERGE" = now ] || [ "$AUTO_MERGE_ALLOWED" = true ] || die "$REPO does not allow automerge."
    CMD=(gh pr merge "$PR_NUMBER" --repo "$REPO" "--$MERGE_METHOD" --match-head-commit "$HEAD_SHA")
    # Where automerge is allowed, `--auto` lets GitHub merge at once when nothing
    # blocks and otherwise wait, so a check that just started doesn't fail it.
    [ "$AUTO_MERGE_ALLOWED" = true ] && CMD+=(--auto)
    if [ "$DRY" = yes ]; then
        out=""; for a in "${CMD[@]}"; do out="$out $(sq "$a")"; done
        printf 'would run:%s\n' "$out" >&2
        RESULT=would
    else
        OK=yes
        ERROR="$("${CMD[@]}" 2>&1 >/dev/null)" || OK=no
        # GitHub refuses automerge for a PR that can already merge.
        if [ "$OK" = no ] && [ "$AUTO_MERGE_ALLOWED" = true ] && printf '%s' "$ERROR" | grep -qi 'clean status'; then
            unset 'CMD[${#CMD[@]}-1]'
            OK=yes
            ERROR="$("${CMD[@]}" 2>&1 >/dev/null)" || OK=no
        fi
        if [ "$OK" = yes ]; then
            ERROR=""
            RESULT="$(gh pr view "$PR_NUMBER" --repo "$REPO" --json state,autoMergeRequest \
                -q 'if .state == "MERGED" then "merged" elif .autoMergeRequest then "auto-enabled" else "merged" end')"
        else
            RESULT=failed
        fi
    fi
fi

emit RESULT "$RESULT"
[ "$RESULT" = failed ] && emit ERROR "$ERROR"
emit PR_URL "$PR_URL"
[ "$RESULT" != failed ]
