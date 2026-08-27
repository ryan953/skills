#!/usr/bin/env bash
# collect.sh — pick the PRs the evaluation will judge, in two arms.
#
#   merged  — reviewers saw it and it landed
#   closed  — it never landed
#   seer    — a bot opened it and one named human merged or closed it
#
# The first two default to running together. The merged arm on its own is
# survivorship bias: a change bad enough to be abandoned never appears in it,
# and those are the cases a reject is meant to catch.
#
# The `seer` arm is the sharpest signal available and the closest match to what
# this skill is actually for. A Seer/autofix PR carries the whole chain by
# construction — a Sentry issue, an RCA, a stated fix — and one person's
# merge-or-close IS the verdict, with no need to infer intent from review
# comments. It inverts the human-authorship filter on purpose: the *code* being
# bot-written is the point, and what makes it ground truth is that the *judgement*
# was a human's.
#
# Usage:
#   collect.sh --repo getsentry/sentry [--label Frontend]
#              [--arm both|merged|closed|seer|all] [--limit 40]
#              [--out cases.raw.jsonl] [--since 2025-01-01]
#              [--bot-author app/seer-by-sentry] [--decider ryan953]
#
# Needs `gh`. Emits one raw JSON object per line; feed it to slice.sh.

# ---- pure filters (sourced by collect.test.sh) ------------------------------

# is_human_authored <login> <is_bot> <commit-trailers>
#
# For the merged/closed arms, where the evaluation is about agreeing with human
# reviewers on human-written code. An AI co-authored PR there would quietly turn
# the test into "does this skill agree with the model that wrote the patch".
# The `seer` arm deliberately does not apply this filter — see the header.
is_human_authored() {
    local login="${1-}" is_bot="${2-false}" trailers="${3-}"
    [ "$is_bot" = true ] && return 1
    case "$login" in
        *'[bot]'|seer-by-sentry|renovate|dependabot|getsentry-bot|codecov*) return 1 ;;
    esac
    printf '%s' "$trailers" | grep -qiE 'co-authored-by:.*(claude|seer|copilot|cursor|devin|codex)' && return 1
    printf '%s' "$trailers" | grep -qiE 'generated with \[?claude|🤖 generated' && return 1
    return 0
}

# is_fix_shaped <title> <branch>
#
# This skill judges fixes, so a feature PR is out of scope — its verdict would be
# needs-human by construction and would say nothing about precision.
is_fix_shaped() {
    local t b
    t="$(printf '%s' "${1-}" | tr '[:upper:]' '[:lower:]')"
    b="$(printf '%s' "${2-}" | tr '[:upper:]' '[:lower:]')"
    case "$t" in
        fix\(*|fix:*|fix\ *|hotfix*|"revert "*) return 0 ;;
        *lint*|*prettier*|*biome*|*typecheck*|*"type error"*) return 0 ;;
    esac
    case "$b" in
        fix/*|hotfix/*|bugfix/*|lint/*) return 0 ;;
    esac
    return 1
}

# build_query <arm> <label> <since> <bot-author> — the search string for one arm.
#
# Pure, so collect.test.sh can pin it. It was inline in fetch_arm before, which
# meant nothing covered it, which is how `--arm seer` shipped dispatching to a
# query that filtered on neither the author nor the state — returning every PR
# in the repo, all of which the bot filter then threw away. Zero cases, no error.
build_query() {
    local arm="$1" label="${2-}" since="${3-}" bot="${4-}" q="is:pr"
    case "$arm" in
        merged) q="$q is:merged" ;;
        closed) q="$q is:closed is:unmerged" ;;
        # Both outcomes: the merge and the close are each a decision, and a
        # sample of only the merges would measure nothing but agreement.
        seer)   q="$q is:closed author:$bot" ;;
        *)      return 1 ;;
    esac
    # A label filter is the human arms' way of scoping to frontend work. The
    # seer arm scopes by author instead, and autofix PRs are rarely labelled, so
    # applying it there would empty the sample.
    [ -n "$label" ] && [ "$arm" != seer ] && q="$q label:\"$label\""
    [ -n "$since" ] && q="$q created:>=$since"
    printf '%s\n' "$q"
}

[ "${BASH_SOURCE[0]}" = "${0}" ] || return 0

# ---- CLI --------------------------------------------------------------------
set -euo pipefail

REPO=""; LABEL=""; ARM=both; LIMIT=40; OUT="-"; SINCE=""
BOT_AUTHOR="app/seer-by-sentry"; DECIDER=""
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) REPO="$2"; shift 2 ;;
        --label) LABEL="$2"; shift 2 ;;
        --arm) ARM="$2"; shift 2 ;;
        --bot-author) BOT_AUTHOR="$2"; shift 2 ;;
        --decider) DECIDER="$2"; shift 2 ;;
        --limit) LIMIT="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --since) SINCE="$2"; shift 2 ;;
        *) printf 'unknown flag: %s\n' "$1" >&2; exit 1 ;;
    esac
done
[ -n "$REPO" ] || { printf 'need --repo owner/name\n' >&2; exit 1; }
command -v gh >/dev/null 2>&1 || { printf 'gh (GitHub CLI) not found on PATH\n' >&2; exit 1; }

LIST_FIELDS=number,title,url,author,headRefName,state,createdAt,mergedAt,closedAt,isDraft
DETAIL_FIELDS=number,title,url,body,state,author,headRefName,baseRefName,headRefOid,createdAt,mergedAt,closedAt,mergedBy,commits,reviews,comments,reviewDecision,files

fetch_arm() {   # fetch_arm <merged|closed|seer>
    local arm="$1" q
    q="$(build_query "$arm" "$LABEL" "$SINCE" "$BOT_AUTHOR")" || {
        printf 'unknown arm: %s\n' "$arm" >&2; echo '[]'; return; }
    # `gh pr list --search` rather than --state: is:unmerged has no --state
    # equivalent, and mixing the two silently returns merged PRs in the closed arm.
    gh pr list --repo "$REPO" --limit "$LIMIT" --search "$q" --json "$LIST_FIELDS" 2>/dev/null || echo '[]'
}

emit_cases() {
    local arm="$1" list n i number title login is_bot branch draft detail trailers decided_by
    list="$(fetch_arm "$arm")"
    n="$(printf '%s' "$list" | jq 'length')"
    printf 'arm %s: %s candidate(s)\n' "$arm" "$n" >&2
    for ((i = 0; i < n; i++)); do
        number="$(printf '%s' "$list" | jq -r ".[$i].number")"
        title="$(printf '%s' "$list" | jq -r ".[$i].title")"
        login="$(printf '%s' "$list" | jq -r ".[$i].author.login // \"\"")"
        is_bot="$(printf '%s' "$list" | jq -r ".[$i].author.is_bot // false")"
        branch="$(printf '%s' "$list" | jq -r ".[$i].headRefName // \"\"")"
        draft="$(printf '%s' "$list" | jq -r ".[$i].isDraft // false")"

        [ "$draft" = true ] && continue
        # A Seer PR is a fix by construction and its title conventions are the
        # bot's, so the shape filter does not apply. Nor does the human-author
        # filter: on this arm the code being bot-written is the POINT, and
        # applying it would reject every case (seer-by-sentry is in the bot
        # list) and return an empty sample without saying so.
        if [ "$arm" != seer ]; then
            is_fix_shaped "$title" "$branch" || continue
        fi

        detail="$(gh pr view "$number" --repo "$REPO" --json "$DETAIL_FIELDS" 2>/dev/null || echo '')"
        [ -n "$detail" ] || continue

        if [ "$arm" != seer ]; then
            # Author trailers live on the commits, not the PR record, so the
            # AI-co-authorship check needs the detail fetch.
            trailers="$(printf '%s' "$detail" | jq -r '[.commits[]?.messageBody // ""] | join("\n")')"
            is_human_authored "$login" "$is_bot" "$trailers" || continue
        fi

        # Who actually decided. GitHub reports it in two places depending on the
        # outcome — mergedBy on a merge, closed_by on a close — and neither alone
        # covers both halves of the seer arm.
        decided_by="$(printf '%s' "$detail" | jq -r '.mergedBy.login // ""')"
        [ -n "$decided_by" ] || decided_by="$(gh api "repos/$REPO/issues/$number" --jq '.closed_by.login // ""' 2>/dev/null || true)"
        # The seer arm is ground truth only when a named human made the call.
        if [ "$arm" = seer ] && [ -n "$DECIDER" ] && [ "$decided_by" != "$DECIDER" ]; then
            continue
        fi

        printf '%s' "$detail" | jq -c --arg arm "$arm" --arg repo "$REPO" --arg by "$decided_by" \
            '. + {arm:$arm, repo:$repo, decided_by:$by}'
    done
}

{
    case "$ARM" in
        both)   emit_cases merged; emit_cases closed ;;
        merged) emit_cases merged ;;
        closed) emit_cases closed ;;
        seer)   emit_cases seer ;;
        all)    emit_cases merged; emit_cases closed; emit_cases seer ;;
        *) printf 'unknown --arm: %s\n' "$ARM" >&2; exit 1 ;;
    esac
} > >([ "$OUT" = - ] && cat || cat > "$OUT")
wait
