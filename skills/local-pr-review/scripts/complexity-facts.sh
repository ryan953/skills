#!/usr/bin/env bash
# complexity-facts.sh — measure the diff, so the complexity call is a judgement
# about facts rather than a guess about a diff nobody counted.
#
# The Haiku subagent that picks a tier gets this file and nothing else. That keeps
# it cheap (no diff in its context) and keeps the tier reproducible: same tree ->
# same facts -> same tier. Everything measurable is measured here; the subagent
# only decides which tier the numbers add up to.
#
# Usage:
#   complexity-facts.sh [--base <ref>] [--cache-dir <dir>]
#
# --base defaults to the fork point computed by the `diff` skill's
# detect-range.sh, so the facts cover the same range revdiff will show.
#
# Output: eval-safe KEY='value' lines — FACTS BASE FILES ADDED DELETED FRONTEND
# plus the boolean flags. The facts file itself is markdown, for the subagent.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

BASE=""
CACHE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --base) BASE="$2"; shift 2 ;;
        --base=*) BASE="${1#--base=}"; shift ;;
        --cache-dir) CACHE="$2"; shift 2 ;;
        --cache-dir=*) CACHE="${1#--cache-dir=}"; shift ;;
        *) die "unknown argument: $1" ;;
    esac
done

git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"

# Same base revdiff will use, so the facts describe the diff the reviewer sees.
# detect-range.sh emits `arg<TAB><value>`; the first non-flag arg is the base.
if [ -z "$BASE" ]; then
    if DETECT="$(find_sibling_script diff detect-range.sh)"; then
        while IFS=$'\t' read -r kind val; do
            [ "$kind" = arg ] || continue
            case "$val" in --*) continue ;; esac
            BASE="$val"; break
        done < <(bash "$DETECT" 2>/dev/null || true)
    fi
fi
# No trunk to fork from (fresh repo, or detached with nothing above) — the last
# commit is the only defensible range.
[ -n "$BASE" ] || BASE="$(git rev-parse HEAD~1 2>/dev/null || git rev-parse HEAD)"

CACHE="${CACHE:-$(cache_dir "$(repo_slug || echo local)" "$(git rev-parse HEAD)")}"
FACTS="$CACHE/complexity-facts.md"

# `git diff --numstat <base>` is base..worktree: committed, staged and unstaged
# all at once. Untracked files are invisible to it, so they're appended as
# all-added — a brand new file is the most complexity-relevant thing there is.
NUMSTAT="$(git diff --numstat "$BASE" 2>/dev/null || true)"
while IFS= read -r f; do
    [ -n "$f" ] || continue
    n="$(wc -l < "$f" 2>/dev/null | tr -d ' ')"
    printf '%s\t0\t%s\n' "${n:-0}" "$f"
done < <(git ls-files --others --exclude-standard 2>/dev/null || true) > "$CACHE/.untracked.numstat"
NUMSTAT="$NUMSTAT
$(cat "$CACHE/.untracked.numstat")"
rm -f "$CACHE/.untracked.numstat"

PATHS="$(printf '%s\n' "$NUMSTAT" | awk -F'\t' 'NF>=3 && $3!="" {print $3}')"
FILES="$(printf '%s\n' "$PATHS" | grep -c . || true)"
ADDED="$(printf '%s\n' "$NUMSTAT" | awk -F'\t' '$1 ~ /^[0-9]+$/ {s+=$1} END {print s+0}')"
DELETED="$(printf '%s\n' "$NUMSTAT" | awk -F'\t' '$2 ~ /^[0-9]+$/ {s+=$2} END {print s+0}')"

# One grep per concern, over paths only. Case-insensitive and deliberately loose:
# a false positive costs a slightly deeper review, a false negative costs a missed
# auth bug.
has() { printf '%s\n' "$PATHS" | grep -Eiq "$1" && printf 'yes' || printf 'no'; }

TESTS="$(has '(^|/)(tests?|__tests__|spec)/|[._-](test|spec)\.[a-z]+$|_test\.(py|go|rb)$')"
MIGRATIONS="$(has '(^|/)migrations?/|\.sql$')"
SENSITIVE="$(has 'auth|login|session|token|permission|password|credential|secret|crypto|payment|billing|stripe|subscription|invoice')"
LOCKFILES="$(has '(^|/)(pnpm-lock\.yaml|yarn\.lock|package-lock\.json|Cargo\.lock|poetry\.lock|uv\.lock|Gemfile\.lock|requirements[^/]*\.txt)$')"
CI="$(has '(^|/)\.github/workflows/|(^|/)\.gitlab-ci|(^|/)Jenkinsfile|(^|/)\.circleci/')"
GENERATED="$(has '\.snap$|(^|/)(dist|build|__generated__)/|\.generated\.|\.pb\.go$')"
FRONTEND="$(has '\.(tsx|jsx|vue|svelte|css|scss|less|sass|html)$|(^|/)(components|static/app|src/app|styles)/')"
DEPS="$(has '(^|/)(package\.json|pyproject\.toml|Cargo\.toml|go\.mod|Gemfile|requirements[^/]*\.txt)$')"

# Docs-only is the one flag that must be about *every* path, not any of them:
# it's the signal that no code changed at all.
if [ "$FILES" -gt 0 ] && ! printf '%s\n' "$PATHS" | grep -Eqv '\.(md|mdx|txt|rst)$|(^|/)docs?/|(^|/)CHANGELOG'; then
    DOCS_ONLY=yes
else
    DOCS_ONLY=no
fi

{
    printf '# Diff facts\n\n'
    printf -- '- base: `%s`\n' "$BASE"
    printf -- '- files changed: **%s**\n' "$FILES"
    printf -- '- lines: **+%s / -%s**\n\n' "$ADDED" "$DELETED"
    printf '## Signals\n\n'
    printf '| signal | value |\n|---|---|\n'
    printf '| touches tests | %s |\n' "$TESTS"
    printf '| touches db migrations or SQL | %s |\n' "$MIGRATIONS"
    printf '| touches auth / payments / secrets | %s |\n' "$SENSITIVE"
    printf '| touches dependency manifests | %s |\n' "$DEPS"
    printf '| touches lockfiles | %s |\n' "$LOCKFILES"
    printf '| touches CI config | %s |\n' "$CI"
    printf '| touches generated output | %s |\n' "$GENERATED"
    printf '| frontend files | %s |\n' "$FRONTEND"
    printf '| documentation only | %s |\n\n' "$DOCS_ONLY"
    printf '## File types\n\n```\n'
    # One awk rather than awk|sed: BSD sed reads `t` with no label as taking the
    # rest of the line *as* the label, so the portable form isn't worth it.
    printf '%s\n' "$PATHS" \
        | awk -F/ '{ f=$NF
                     if (match(f, /\.[A-Za-z0-9]+$/)) print substr(f, RSTART)
                     else print "(no extension)" }' \
        | sort | uniq -c | sort -rn | head -20
    printf '```\n\n## Per-file churn (largest first, capped at 40)\n\n```\n'
    # Sort on an explicit total-churn key, then cut it off: sorting the formatted
    # line instead puts `sort -k` on whichever column the padding lands in, which
    # silently produces an unsorted "largest first" list. Binary files come back
    # from numstat as `-`/`-` and sort as 0 churn.
    printf '%s\n' "$NUMSTAT" \
        | awk -F'\t' 'NF>=3 && $3!="" {
              a = ($1 ~ /^[0-9]+$/) ? $1 : 0
              d = ($2 ~ /^[0-9]+$/) ? $2 : 0
              printf "%d\t+%-6s -%-6s %s\n", a + d, $1, $2, $3 }' \
        | sort -rn | head -40 | cut -f2-
    printf '```\n'
} > "$FACTS"

emit FACTS      "$FACTS"
emit BASE       "$BASE"
emit FILES      "$FILES"
emit ADDED      "$ADDED"
emit DELETED    "$DELETED"
emit FRONTEND   "$FRONTEND"
emit TESTS      "$TESTS"
emit MIGRATIONS "$MIGRATIONS"
emit SENSITIVE  "$SENSITIVE"
emit LOCKFILES  "$LOCKFILES"
emit CI         "$CI"
emit GENERATED  "$GENERATED"
emit DEPS       "$DEPS"
emit DOCS_ONLY  "$DOCS_ONLY"
