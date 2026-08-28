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
#              [--involves ryan953] [--keep-bot-closed]
#
# --involves ranks rather than filters: PRs that person touched come out first,
# and the rest follow, so --max-cases takes the involved ones and still fills up.
# --decider is the older HARD filter on who merged or closed it.
#
# A PR closed by a bot is dropped unless --keep-bot-closed. getsantry[bot] closes
# stale PRs on a timer; that close is not a human verdict and cannot be ground
# truth for anything.
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

# is_bot_login <login>
#
# For the CLOSER, not the author. The seer arm is ground truth only because a
# human made the call, and getsantry[bot] closes stale PRs on a timer: that
# close says nothing about the patch. Six of nineteen closed cases in a real
# sample were the bot's, and each one entered the sample as a decision.
is_bot_login() {
    case "${1-}" in
        ''|*'[bot]'|getsantry|getsentry-bot|sentry-io|seer-by-sentry|codecov*|github-actions|renovate|dependabot) return 0 ;;
    esac
    return 1
}

# involvement <login> <detail-json> <decided-by>
#
# How the person is tied to this PR, strongest first. Ranking, not filtering:
# only 7 seer PRs in getsentry/sentry involve any one reviewer, so a hard filter
# would leave nothing to measure. Cases come out ordered by this, and --max-cases
# then takes the involved ones first.
involvement() {
    local who="${1-}" detail="${2-}" decided="${3-}"
    [ -n "$who" ] || { printf '0\t\n'; return; }
    [ "$decided" = "$who" ] && { printf '3\tdecider\n'; return; }
    if printf '%s' "$detail" | jq -e --arg w "$who" \
        '[(.reviews // [])[] | select((.author.login // "") == $w)] | length > 0' >/dev/null 2>&1; then
        printf '2\treviewer\n'; return
    fi
    if printf '%s' "$detail" | jq -e --arg w "$who" \
        '[(.comments // [])[] | select((.author.login // "") == $w)] | length > 0' >/dev/null 2>&1; then
        printf '1\tcommenter\n'; return
    fi
    printf '0\t\n'
}

# build_query <arm> <label> <since> <bot-author> [involves] — one arm's search.
#
# Pure, so collect.test.sh can pin it. It was inline in fetch_arm before, which
# meant nothing covered it, which is how `--arm seer` shipped dispatching to a
# query that filtered on neither the author nor the state — returning every PR
# in the repo, all of which the bot filter then threw away. Zero cases, no error.
build_query() {
    local arm="$1" label="${2-}" since="${3-}" bot="${4-}" involves="${5-}" q="is:pr"
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
    # `involves:` covers author, assignee, mentions, commenter and reviewer --
    # wider than any single one of them, which is what "been involved with" means.
    [ -n "$involves" ] && q="$q involves:$involves"
    printf '%s\n' "$q"
}

[ "${BASH_SOURCE[0]}" = "${0}" ] || return 0

# ---- CLI --------------------------------------------------------------------
set -euo pipefail

REPO=""; LABEL=""; ARM=both; LIMIT=40; OUT="-"; SINCE=""
BOT_AUTHOR="app/seer-by-sentry"; DECIDER=""; INVOLVES=""; KEEP_BOT_CLOSED=""
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) REPO="$2"; shift 2 ;;
        --label) LABEL="$2"; shift 2 ;;
        --arm) ARM="$2"; shift 2 ;;
        --bot-author) BOT_AUTHOR="$2"; shift 2 ;;
        --decider) DECIDER="$2"; shift 2 ;;
        --involves) INVOLVES="$2"; shift 2 ;;
        --keep-bot-closed) KEEP_BOT_CLOSED=1; shift ;;
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

search_prs() {   # search_prs <query>
    # `gh pr list --search` rather than --state: is:unmerged has no --state
    # equivalent, and mixing the two silently returns merged PRs in the closed arm.
    gh pr list --repo "$REPO" --limit "$LIMIT" --search "$1" --json "$LIST_FIELDS" 2>/dev/null || echo '[]'
}

fetch_arm() {   # fetch_arm <merged|closed|seer>
    local arm="$1" q qi involved rest
    q="$(build_query "$arm" "$LABEL" "$SINCE" "$BOT_AUTHOR")" || {
        printf 'unknown arm: %s\n' "$arm" >&2; echo '[]'; return; }
    [ -n "$INVOLVES" ] || { search_prs "$q"; return; }

    # Two passes, involved first, deduplicated by number. One pass with
    # `involves:` alone would cap the sample at however many PRs that person
    # touched -- seven, across the whole repo -- and one without it would bury
    # them somewhere past --max-cases. This is what "prefer" has to mean.
    qi="$(build_query "$arm" "$LABEL" "$SINCE" "$BOT_AUTHOR" "$INVOLVES")"
    involved="$(search_prs "$qi")"
    rest="$(search_prs "$q")"
    # Order-preserving dedup: `unique_by` would re-sort by number and throw the
    # involved-first ordering away, which is the only thing this function is for.
    printf '%s' "$involved" | jq -c --argjson rest "$rest" '
        (. + $rest)
        | reduce .[] as $p ({seen: {}, out: []};
            ($p.number | tostring) as $k
            | if .seen[$k] then . else .seen[$k] = true | .out += [$p] end)
        | .out' 2>/dev/null || printf '%s' "$involved"
}

emit_cases() {
    local arm="$1" list n i number title login is_bot branch draft detail trailers decided_by
    local inv inv_rank inv_how
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
        # A stale-bot close is a timer firing, not a verdict. Counted rather
        # than dropped in silence: an empty sample and a heavily filtered one
        # look identical by the time score.sh sees them.
        if [ -z "$KEEP_BOT_CLOSED" ] && is_bot_login "$decided_by"; then
            BOT_CLOSED=$((BOT_CLOSED + 1))
            continue
        fi

        inv="$(involvement "$INVOLVES" "$detail" "$decided_by")"
        inv_rank="${inv%%	*}"
        inv_how="${inv#*	}"
        [ "$inv_rank" = 0 ] || INVOLVED_N=$((INVOLVED_N + 1))

        printf '%s' "$detail" | jq -c --arg arm "$arm" --arg repo "$REPO" --arg by "$decided_by" \
            --argjson rank "$inv_rank" --arg how "$inv_how" \
            '. + {arm:$arm, repo:$repo, decided_by:$by,
                  involvement: $rank, involved_as: $how}'
    done
}

# A plain file, not `> >(cat > "$OUT")`. Process substitution plus a bare `wait`
# only flushes reliably on bash 5.1+, and this is written for macOS's 3.2; a
# truncated output file here is indistinguishable from an empty sample.
BOT_CLOSED=0
INVOLVED_N=0

TMP_OUT="$(mktemp "${TMPDIR:-/tmp}/autofix-review-out.XXXXXX")"
trap 'rm -f "$TMP_OUT"' EXIT

{
    case "$ARM" in
        both)   emit_cases merged; emit_cases closed ;;
        merged) emit_cases merged ;;
        closed) emit_cases closed ;;
        seer)   emit_cases seer ;;
        all)    emit_cases merged; emit_cases closed; emit_cases seer ;;
        *) printf 'unknown --arm: %s\n' "$ARM" >&2; exit 1 ;;
    esac
} > "$TMP_OUT"
[ "$BOT_CLOSED" -eq 0 ] || \
    printf 'dropped %s PR(s) closed by a bot (no human verdict); --keep-bot-closed keeps them\n' \
        "$BOT_CLOSED" >&2
[ -z "$INVOLVES" ] || \
    printf '%s of the collected PR(s) involve %s; they are ordered first\n' \
        "$INVOLVED_N" "$INVOLVES" >&2

# Involved cases first, then by PR number descending so a rerun of the same
# sample produces a byte-identical file. run.sh takes --max-cases in file order,
# so this ordering is what makes --involves mean anything.
SORTED="$(mktemp "${TMPDIR:-/tmp}/autofix-review-sorted.XXXXXX")"
jq -s -c 'sort_by(-(.involvement // 0), -(.number // 0)) | .[]' "$TMP_OUT" > "$SORTED" 2>/dev/null \
    || cp "$TMP_OUT" "$SORTED"
rm -f "$TMP_OUT"
if [ "$OUT" = - ]; then cat "$SORTED"; rm -f "$SORTED"; else mv "$SORTED" "$OUT"; fi
