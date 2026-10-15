#!/usr/bin/env bash
# approve.sh — approve the PR, and for bot PRs do the follow-through that makes it
# mergeable: mark it ready and add the getsentry test label. Then report what the
# merge question should offer.
#
# Usage:
#   approve.sh [<pr-number-or-url>] [--repo owner/name] [--body-file <path|->] [--dry-run]
#
# --body-file is the comment exactly as the user wrote it; `-` reads stdin. Leave
# it out (or pass an empty body) to approve without a comment. An existing approval
# from me is never repeated, so the body is ignored then.
#
# Output: eval-safe KEY='value' lines:
#   APPROVED     yes | already | would
#   READIED      yes | no | would
#   LABEL_ADDED  yes | no | would
#   NEXT         done | ask-merge | automerge-on
#   RECOMMEND, MERGE_OPTIONS, SUMMARY, PR_URL   (from a fresh pr-facts.sh run)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

FACT_ARGS=()
BODY_FILE=""
DRY=no
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) FACT_ARGS+=(--repo "$2"); shift 2 ;;
        --body-file) BODY_FILE="$2"; shift 2 ;;
        --dry-run) DRY=yes; shift ;;
        -*) die "unknown flag: $1" ;;
        *) FACT_ARGS+=("$1"); shift ;;
    esac
done

run() {
    if [ "$DRY" = yes ]; then
        local a out=""
        for a in "$@"; do out="$out $(sq "$a")"; done
        printf 'would run:%s\n' "$out" >&2
    else
        "$@"
    fi
}
did() { [ "$DRY" = yes ] && printf 'would' || printf 'yes'; }

# Captured before eval: `eval "$(...)"` would swallow a pr-facts.sh failure.
FACTS="$("$HERE/pr-facts.sh" ${FACT_ARGS[0]+"${FACT_ARGS[@]}"})" || exit 1
eval "$FACTS"
[ "$NEXT" = stop ] && die "$STOP_REASON"

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
    run gh pr review "$PR_NUMBER" --repo "$REPO" --approve ${BODY_ARGS[0]+"${BODY_ARGS[@]}"} >&2
    APPROVED="$(did)"
fi

READIED=no LABEL_ADDED=no
if [ "$AUTHOR_CLASS" = bot ]; then
    # A draft cannot merge, and the approval is what vouches for it.
    if [ "$IS_DRAFT" = true ]; then
        run gh pr ready "$PR_NUMBER" --repo "$REPO" >&2
        READIED="$(did)"
    fi
    if [ "$IS_SENTRY" = yes ] && [ "$HAS_TEST_LABEL" = no ]; then
        run gh pr edit "$PR_NUMBER" --repo "$REPO" --add-label "$TEST_LABEL" >&2
        LABEL_ADDED="$(did)"
    fi
fi

emit APPROVED    "$APPROVED"
emit READIED     "$READIED"
emit LABEL_ADDED "$LABEL_ADDED"

if [ "$AUTHOR_CLASS" != bot ]; then
    emit NEXT   'done'
    emit PR_URL "$PR_URL"
    exit 0
fi

# Re-read after acting: the approval can change the merge state, and the new
# label queues checks the first read could not see.
REFRESH=(--repo "$REPO" "$PR_NUMBER")
[ "$LABEL_ADDED" = no ] || REFRESH+=(--label-added)
FACTS="$("$HERE/pr-facts.sh" "${REFRESH[@]}")" || exit 1
eval "$FACTS"

if [ "$AUTO_MERGE_ON" = yes ]; then emit NEXT automerge-on; else emit NEXT ask-merge; fi
emit RECOMMEND     "$RECOMMEND"
emit MERGE_OPTIONS "$MERGE_OPTIONS"
emit SUMMARY       "$SUMMARY"
emit PR_URL        "$PR_URL"
