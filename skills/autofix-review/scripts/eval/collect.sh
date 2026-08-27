#!/usr/bin/env bash
# collect.sh — pick the PRs the evaluation will judge, in two arms.
#
#   merged  — reviewers saw it and it landed
#   closed  — it never landed
#
# Both arms, always, unless you ask otherwise. The merged arm on its own is
# survivorship bias: a change bad enough to be abandoned never appears in it,
# and those are the cases a reject is meant to catch.
#
# Usage:
#   collect.sh --repo getsentry/sentry [--label Frontend] [--arm both|merged|closed]
#              [--limit 40] [--out cases.raw.jsonl] [--since 2025-01-01]
#
# Needs `gh`. Emits one raw JSON object per line; feed it to slice.sh.

# ---- pure filters (sourced by collect.test.sh) ------------------------------

# is_human_authored <login> <is_bot> <commit-trailers>
#
# The evaluation is about agreeing with human reviewers on human-written code.
# An AI co-authored PR is a different distribution and would quietly become a
# test of whether this skill agrees with the model that wrote the patch.
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
        ref\(lint*|*lint*|*eslint*|*prettier*|*biome*|*typecheck*|*"type error"*) return 0 ;;
    esac
    case "$b" in
        fix/*|hotfix/*|bugfix/*|lint/*) return 0 ;;
    esac
    return 1
}

[ "${BASH_SOURCE[0]}" = "${0}" ] || return 0

# ---- CLI --------------------------------------------------------------------
set -euo pipefail

REPO=""; LABEL=""; ARM=both; LIMIT=40; OUT="-"; SINCE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) REPO="$2"; shift 2 ;;
        --label) LABEL="$2"; shift 2 ;;
        --arm) ARM="$2"; shift 2 ;;
        --limit) LIMIT="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --since) SINCE="$2"; shift 2 ;;
        *) printf 'unknown flag: %s\n' "$1" >&2; exit 1 ;;
    esac
done
[ -n "$REPO" ] || { printf 'need --repo owner/name\n' >&2; exit 1; }
command -v gh >/dev/null 2>&1 || { printf 'gh (GitHub CLI) not found on PATH\n' >&2; exit 1; }

LIST_FIELDS=number,title,url,author,headRefName,state,createdAt,mergedAt,closedAt,isDraft
DETAIL_FIELDS=number,title,url,body,state,author,headRefName,baseRefName,headRefOid,createdAt,mergedAt,closedAt,commits,reviews,comments,reviewDecision,files

fetch_arm() {   # fetch_arm <merged|closed>
    local arm="$1" q="is:pr"
    case "$arm" in
        merged) q="$q is:merged" ;;
        closed) q="$q is:closed is:unmerged" ;;
    esac
    [ -n "$LABEL" ] && q="$q label:\"$LABEL\""
    [ -n "$SINCE" ] && q="$q created:>=$SINCE"
    # `gh pr list --search` rather than --state: is:unmerged has no --state
    # equivalent, and mixing the two silently returns merged PRs in the closed arm.
    gh pr list --repo "$REPO" --limit "$LIMIT" --search "$q" --json "$LIST_FIELDS" 2>/dev/null || echo '[]'
}

emit_cases() {
    local arm="$1" list n i number title login is_bot branch draft detail trailers
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
        is_fix_shaped "$title" "$branch" || continue

        detail="$(gh pr view "$number" --repo "$REPO" --json "$DETAIL_FIELDS" 2>/dev/null || echo '')"
        [ -n "$detail" ] || continue

        # Author trailers live on the commits, not the PR record, so the
        # AI-co-authorship check needs the detail fetch.
        trailers="$(printf '%s' "$detail" | jq -r '[.commits[]?.messageBody // ""] | join("\n")')"
        is_human_authored "$login" "$is_bot" "$trailers" || continue

        printf '%s' "$detail" | jq -c --arg arm "$arm" --arg repo "$REPO" '. + {arm:$arm, repo:$repo}'
    done
}

{
    case "$ARM" in
        both)   emit_cases merged; emit_cases closed ;;
        merged) emit_cases merged ;;
        closed) emit_cases closed ;;
        *) printf 'unknown --arm: %s\n' "$ARM" >&2; exit 1 ;;
    esac
} > >([ "$OUT" = - ] && cat || cat > "$OUT")
wait
