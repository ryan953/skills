#!/usr/bin/env bash
# verdict.sh — record the review's outcome on the PR, and for bot PRs take the
# follow-on actions that outcome implies.
#
# Three outcomes, because "no verdict" is a real one: reading a PR and choosing
# not to formally approve or block it is normal, and forcing a binary would put
# an approval on the record that nobody meant.
#
# The bot-PR extras (mark ready for review, add the test-trigger label) fire on
# approval only, and only for bots: a bot PR sits in draft until something
# vouches for it, whereas a human's PR readiness is the human's call.
#
# Usage:
#   verdict.sh --pr <n> [--repo owner/name] --verdict approve|request-changes|comment|none \
#              [--body <text>] [--class mine|bot|other] [--dry-run]
#
# GitHub refuses to let you approve your own PR, so --class mine + approve
# degrades to a plain comment rather than failing the whole step.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

PR="" REPO="" VERDICT="" BODY="" CLASS="other" DRY=no
READY_LABEL="${LPR_TEST_LABEL:-Trigger: getsentry tests}"
while [ $# -gt 0 ]; do
    case "$1" in
        --pr) PR="$2"; shift 2 ;;
        --repo) REPO="$2"; shift 2 ;;
        --verdict) VERDICT="$2"; shift 2 ;;
        --body) BODY="$2"; shift 2 ;;
        --class) CLASS="$2"; shift 2 ;;
        --dry-run) DRY=yes; shift ;;
        *) die "unknown argument: $1" ;;
    esac
done
[ -n "$PR" ] || die "--pr <number> is required"
[ -n "$VERDICT" ] || die "--verdict approve|request-changes|comment|none is required"
command -v gh >/dev/null 2>&1 || die "gh (GitHub CLI) not found on PATH"

REPO="${REPO:-$(repo_slug)}"
[ -n "$REPO" ] || die "could not determine owner/name; pass --repo"
REPO_ARGS=(--repo "$REPO")

run() {   # echo under --dry-run, execute otherwise
    if [ "$DRY" = yes ]; then
        # Quote anything that isn't a bare word. `$*` would print the test-trigger
        # label as three arguments and a review body as many — the whole point of
        # --dry-run is that what it shows is what would run.
        local a out=""
        for a in "$@"; do
            case "$a" in
                ""|*[!A-Za-z0-9._/=:-]*) out="$out $(sq "$a")" ;;
                *)                       out="$out $a" ;;
            esac
        done
        printf 'would run:%s\n' "$out" >&2
        return 0
    fi
    "$@"
}

case "$VERDICT" in
    approve|request-changes|comment|none) ;;
    *) die "unknown verdict: $VERDICT" ;;
esac

# Self-approval is not a thing GitHub allows; say so and comment instead of
# failing after the review has already been done.
DEGRADED=no
if [ "$VERDICT" = approve ] && [ "$CLASS" = mine ]; then
    VERDICT=comment
    DEGRADED=yes
fi

# An array, not a bare ${BODY:+...}: an unquoted expansion would split a
# multi-word review body into separate argv entries.
BODY_ARGS=()
[ -n "$BODY" ] && BODY_ARGS=(--body "$BODY")

ACTED=none
case "$VERDICT" in
    approve)
        run gh pr review "$PR" "${REPO_ARGS[@]}" --approve ${BODY_ARGS[0]+"${BODY_ARGS[@]}"}
        ACTED=approve
        ;;
    request-changes)
        [ -n "$BODY" ] || die "--body is required for request-changes (say what to change)"
        run gh pr review "$PR" "${REPO_ARGS[@]}" --request-changes --body "$BODY"
        ACTED=request-changes
        ;;
    comment)
        if [ -n "$BODY" ]; then
            run gh pr review "$PR" "${REPO_ARGS[@]}" --comment --body "$BODY"
            ACTED=comment
        fi
        ;;
    none)
        ;;
esac

# Bot PRs, on approval only: take it out of draft and let CI run. This is the one
# place the flow changes the PR's state rather than commenting on it, so it stays
# narrowly gated.
READIED=no LABELED=no
if [ "$ACTED" = approve ] && [ "$CLASS" = bot ]; then
    DID="$([ "$DRY" = yes ] && printf 'would' || printf 'yes')"
    if run gh pr ready "$PR" "${REPO_ARGS[@]}"; then READIED="$DID"; fi
    if run gh pr edit "$PR" "${REPO_ARGS[@]}" --add-label "$READY_LABEL"; then LABELED="$DID"; fi
fi

emit VERDICT   "$ACTED"
emit DEGRADED  "$DEGRADED"
emit READIED   "$READIED"
emit LABELED   "$LABELED"
emit LABEL     "$READY_LABEL"
emit DRY_RUN   "$DRY"
