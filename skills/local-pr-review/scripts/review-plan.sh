#!/usr/bin/env bash
# review-plan.sh — turn (tier, author class, frontend?) into the exact list of
# review skills to run, where each output is cached, and whether it's already there.
#
# This is the determinism the flow was missing: depth is a table lookup, not a
# per-run judgement call, and a re-review of the same commit reuses what it
# already computed instead of paying for it twice.
#
# Usage:
#   review-plan.sh --tier medium --class mine --frontend yes --cache-dir <dir> \
#                  [--pr <n>] [--repo owner/name] [--add <skill>]... [--skip <skill>]... \
#                  [--only <skill>]... [--refresh]
#
# Output: one TSV record per skill —
#   skill <TAB> runner <TAB> cache_path <TAB> hit|miss <TAB> command <TAB> note
#
# runner=script  -> `command` is runnable right now; run it, it writes cache_path.
# runner=skill   -> `command` is the slash skill to invoke; save its report to
#                   cache_path afterwards so the next pass is a hit.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
# shellcheck source=classify.sh
. "$HERE/classify.sh"

TIER=medium CLASS=mine FRONTEND=no CACHE="" PR="" REPO="" REFRESH=no
ADD=() SKIP=() ONLY=()
while [ $# -gt 0 ]; do
    case "$1" in
        --tier) TIER="$2"; shift 2 ;;
        --class) CLASS="$2"; shift 2 ;;
        --frontend) FRONTEND="$2"; shift 2 ;;
        --cache-dir) CACHE="$2"; shift 2 ;;
        --pr) PR="$2"; shift 2 ;;
        --repo) REPO="$2"; shift 2 ;;
        --add) ADD+=("$2"); shift 2 ;;
        --skip) SKIP+=("$2"); shift 2 ;;
        --only) ONLY+=("$2"); shift 2 ;;
        --refresh) REFRESH=yes; shift ;;
        *) die "unknown argument: $1" ;;
    esac
done
[ -n "$CACHE" ] || die "--cache-dir is required"
mkdir -p "$CACHE"

TIER="$(normalize_tier "$TIER")"

if [ ${#ONLY[@]} -gt 0 ]; then
    PLANNED="$(printf '%s\n' "${ONLY[@]}")"
else
    PLANNED="$(plan_skills "$TIER" "$CLASS" "$FRONTEND")"
    [ ${#ADD[@]} -gt 0 ] && PLANNED="$PLANNED
$(printf '%s\n' "${ADD[@]}")"
fi

in_list() {  # in_list <needle> <item>...
    local n="$1"; shift
    local i; for i in "$@"; do [ "$i" = "$n" ] && return 0; done
    return 1
}

MEAT_SCRIPT="$(find_sibling_script meat-pr-review review.sh || true)"

printf '%s\n' "$PLANNED" | awk 'NF && !seen[$0]++' | while IFS= read -r skill; do
    [ ${#SKIP[@]} -gt 0 ] && in_list "$skill" "${SKIP[@]}" && continue

    runner="$(skill_runner "$skill")"
    out="$CACHE/review-$(slugify "$skill").md"
    note=""

    # A mutating skill on someone else's PR is off the table however it got here —
    # plan_skills won't produce one, but --add/--only can.
    if [ "$(skill_mutates "$skill")" = yes ] && [ "$CLASS" = other ]; then
        note="skipped: mutates code, and this is someone else's PR"
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$skill" skip "$out" skip "" "$note"
        continue
    fi

    if [ "$REFRESH" = no ] && [ -s "$out" ]; then
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$skill" "$runner" "$out" hit "" "cached; read it"
        continue
    fi

    cmd=""
    case "$skill" in
        meat-pr-review)
            if [ -z "$MEAT_SCRIPT" ]; then
                runner=skip; note="skipped: meat-pr-review/scripts/review.sh not found"
            elif [ -z "$PR" ]; then
                runner=skip; note="skipped: needs a PR number (unpushed branch)"
            else
                cmd="bash $(sq "$MEAT_SCRIPT") $(sq "$PR")"
                [ -n "$REPO" ] && cmd="$cmd --repo $(sq "$REPO")"
                cmd="$cmd > $(sq "$out")"
                note="reading diff: run it, then read the summary"
            fi
            ;;
        *)
            cmd="/$skill"
            note="invoke the skill, then write its report to the cache path"
            ;;
    esac

    # A skip is a skip in the status column too, whatever set it — a caller
    # filtering on `miss` to decide what to run must not pick up an entry that
    # was ruled out above for having no command to run.
    status=miss
    [ "$runner" = skip ] && status=skip
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$skill" "$runner" "$out" "$status" "$cmd" "$note"
done

# Nothing planned is a real answer, not a failure: at the `trivial` tier reading
# the diff *is* the review. Say so rather than printing an empty plan.
if [ -z "$(printf '%s\n' "$PLANNED" | awk 'NF')" ]; then
    printf '#\tnone\t%s\tn/a\t\tno review skills for tier=%s — read the diff directly\n' \
        "$CACHE" "$TIER"
fi
