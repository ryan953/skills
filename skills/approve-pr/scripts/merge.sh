#!/usr/bin/env bash
# merge.sh — merge the PR now, or turn on automerge, with the repo's allowed merge
# method. Never passes --admin: a PR that GitHub blocks stays blocked.
#
# Usage:
#   merge.sh [<pr-number-or-url>] [--repo owner/name] --mode now|auto [--dry-run]
#
# Output: eval-safe KEY='value' lines:
#   RESULT          merged | auto-enabled | auto-already | would | failed
#   ERROR           gh's error text when RESULT=failed
#   AUTO_AVAILABLE  true | false — whether automerge is an option after a failure
#   PR_URL
# Exits 1 when RESULT=failed, after printing the keys.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

FACT_ARGS=()
MODE=""
DRY=no
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) FACT_ARGS+=(--repo "$2"); shift 2 ;;
        --mode) MODE="$2"; shift 2 ;;
        --dry-run) DRY=yes; shift ;;
        -*) die "unknown flag: $1" ;;
        *) FACT_ARGS+=("$1"); shift ;;
    esac
done
case "$MODE" in now|auto) ;; *) die "--mode now|auto is required" ;; esac

# Captured before eval: `eval "$(...)"` would swallow a pr-facts.sh failure.
FACTS="$("$HERE/pr-facts.sh" ${FACT_ARGS[0]+"${FACT_ARGS[@]}"})" || exit 1
eval "$FACTS"
[ "$PR_STATE" = OPEN ] || die "PR is $PR_STATE, not open."
[ -n "$MERGE_METHOD" ] || die "$REPO allows no merge method."
if [ "$MODE" = auto ]; then
    [ "$AUTO_MERGE_ALLOWED" = true ] || die "$REPO does not allow automerge."
    if [ "$AUTO_MERGE_ON" = yes ]; then
        emit RESULT auto-already; emit PR_URL "$PR_URL"; exit 0
    fi
fi

CMD=(gh pr merge "$PR_NUMBER" --repo "$REPO" "--$MERGE_METHOD")
[ "$MODE" = auto ] && CMD+=(--auto)

if [ "$DRY" = yes ]; then
    out=""; for a in "${CMD[@]}"; do out="$out $(sq "$a")"; done
    printf 'would run:%s\n' "$out" >&2
    emit RESULT would; emit PR_URL "$PR_URL"; exit 0
fi

if ERR="$("${CMD[@]}" 2>&1 >/dev/null)"; then
    if [ "$MODE" = auto ]; then emit RESULT auto-enabled; else emit RESULT merged; fi
    emit PR_URL "$PR_URL"
else
    emit RESULT failed
    emit ERROR "$ERR"
    emit AUTO_AVAILABLE "$([ "$MODE" = now ] && [ "$AUTO_MERGE_ALLOWED" = true ] && printf true || printf false)"
    emit PR_URL "$PR_URL"
    exit 1
fi
