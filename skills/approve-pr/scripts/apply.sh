#!/usr/bin/env bash
# apply.sh — carry out every answer in one call: approve, then for bot PRs mark a
# draft ready and add the getsentry label, then merge or turn on automerge.
#
# Usage:
#   apply.sh [<pr>] [--repo owner/name] [--body-file <path|->] \
#            [--merge now|auto|none] [--expected-head <sha>] [--dry-run]
#
# --expected-head is the head commit the user saw when they answered. If the PR
# has moved since (a bot rebased or pushed), nothing is done: the user would be
# approving code they never saw. A merge is also pinned to that commit.
#
# --body-file is the comment exactly as the user wrote it; `-` reads stdin. Leave
# it out (or pass an empty body) to approve without a comment. An existing approval
# from me is never repeated, so the body is ignored then. --merge defaults to none.
# Never passes --admin: a PR that GitHub blocks stays blocked.
#
# Output: eval-safe KEY='value' lines:
#   APPROVED        yes | already | would
#   READIED         yes | no | would
#   LABEL_ADDED     yes | no | would
#   RESULT          none | merged | auto-enabled | auto-already | would | failed
#   ERROR           gh's error text when RESULT=failed
#   AUTO_AVAILABLE  true | false — whether automerge is an option after a failure
#   PR_URL
# Exits 1 when RESULT=failed, after printing the keys.

# REPO, PR_NUMBER and the other upper-case facts are set by eval'ing pr-facts.sh.
# shellcheck disable=SC2153

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

FACT_ARGS=()
BODY_FILE=""
MERGE=none
EXPECTED_HEAD=""
DRY=no
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) FACT_ARGS+=(--repo "$2"); shift 2 ;;
        --expected-head) EXPECTED_HEAD="$2"; shift 2 ;;
        --body-file) BODY_FILE="$2"; shift 2 ;;
        --merge) MERGE="$2"; shift 2 ;;
        --dry-run) DRY=yes; shift ;;
        -*) die "unknown flag: $1" ;;
        *) FACT_ARGS+=("$1"); shift ;;
    esac
done
case "$MERGE" in now|auto|none) ;; *) die "--merge must be now, auto, or none" ;; esac

run() {
    if [ "$DRY" = yes ]; then
        local a out=""
        for a in "$@"; do out="$out $(sq "$a")"; done
        printf 'would run:%s\n' "$out" >&2
    else
        "$@" >&2
    fi
}
did() { if [ "$DRY" = yes ]; then printf 'would'; else printf 'yes'; fi; }

# Captured before eval: `eval "$(...)"` would swallow a pr-facts.sh failure.
FACTS="$("$HERE/pr-facts.sh" ${FACT_ARGS[0]+"${FACT_ARGS[@]}"})" || exit 1
eval "$FACTS"
[ "$NEXT" = stop ] && die "$STOP_REASON"
[ "$(fixup_approval_ok "$AUTHOR" "$REPO" "$MY_COMMITS")" = yes ] \
    || die "PR has $MY_COMMITS commit(s) from you, and $AUTHOR in $REPO is not an allowlisted bot PR in getsentry; review and approve it by hand."
case "$HEAD_SHA" in
    "$EXPECTED_HEAD"*) ;;
    *) die "PR head moved from ${EXPECTED_HEAD} to ${HEAD_SHA:0:8} since the question was asked; run /approve-pr again." ;;
esac

if [ "$MY_APPROVAL" = yes ]; then
    APPROVED=already
else
    BODY_ARGS=()
    if [ -n "$BODY_FILE" ]; then
        TMP="$(mktemp)"
        trap 'rm -f "$TMP"' EXIT
        cat -- "$BODY_FILE" > "$TMP"
        # A body of only whitespace is the same as no comment.
        if grep -q '[^[:space:]]' "$TMP"; then BODY_ARGS=(--body-file "$TMP"); fi
    fi
    run gh pr review "$PR_NUMBER" --repo "$REPO" --approve ${BODY_ARGS[0]+"${BODY_ARGS[@]}"}
    APPROVED="$(did)"
fi

READIED=no LABEL_ADDED=no
if [ "$AUTHOR_CLASS" = bot ]; then
    # A draft cannot merge, and the approval is what vouches for it.
    if [ "$IS_DRAFT" = true ]; then
        run gh pr ready "$PR_NUMBER" --repo "$REPO"
        READIED="$(did)"
    fi
    if [ "$IS_SENTRY" = yes ] && [ "$HAS_TEST_LABEL" = no ]; then
        run gh pr edit "$PR_NUMBER" --repo "$REPO" --add-label "$TEST_LABEL"
        LABEL_ADDED="$(did)"
    fi
fi

emit APPROVED    "$APPROVED"
emit READIED     "$READIED"
emit LABEL_ADDED "$LABEL_ADDED"

RESULT=none ERROR="" AUTO_AVAILABLE=false
if [ "$MERGE" = auto ] && [ "$AUTO_MERGE_ON" = yes ]; then
    RESULT=auto-already
elif [ "$MERGE" != none ]; then
    [ -n "$MERGE_METHOD" ] || die "$REPO allows no merge method."
    [ "$MERGE" = now ] || [ "$AUTO_MERGE_ALLOWED" = true ] || die "$REPO does not allow automerge."
    CMD=(gh pr merge "$PR_NUMBER" --repo "$REPO" "--$MERGE_METHOD" --match-head-commit "$HEAD_SHA")
    [ "$MERGE" = auto ] && CMD+=(--auto)
    if [ "$DRY" = yes ]; then
        run "${CMD[@]}"
        RESULT=would
    elif ERROR="$("${CMD[@]}" 2>&1 >/dev/null)"; then
        # `--auto` merges at once when nothing is blocking, so read back which
        # one happened instead of assuming.
        RESULT="$(gh pr view "$PR_NUMBER" --repo "$REPO" --json state,autoMergeRequest \
            -q 'if .state == "MERGED" then "merged" elif .autoMergeRequest then "auto-enabled" else "merged" end')"
        ERROR=""
    else
        RESULT=failed
        [ "$MERGE" = now ] && [ "$AUTO_MERGE_ALLOWED" = true ] && AUTO_AVAILABLE=true
    fi
fi

emit RESULT "$RESULT"
if [ "$RESULT" = failed ]; then
    emit ERROR          "$ERROR"
    emit AUTO_AVAILABLE "$AUTO_AVAILABLE"
fi
emit PR_URL "$PR_URL"
[ "$RESULT" != failed ]
