#!/usr/bin/env bash
# review.sh — produce a "reading diff" for a GitHub PR *or* a local branch by
# running the diff through `meat`.
#
# Usage:
#   review.sh                            # PR for the current branch, else the branch diff
#   review.sh <pr-url-or-number>         # that PR
#   review.sh <branch>                   # that branch's PR, else its local diff
#   review.sh <base>..<head>             # explicit local range (three dots also fine)
#   review.sh --local [<ref>]            # force local, never ask GitHub
#   review.sh --pr <n> [--repo owner/name]
#
# Flags:
#   --local            force local-git mode even when a PR exists
#   --pr <n>           force PR mode
#   --repo owner/name  repo for gh, when run outside that checkout
#   --base <ref>       local mode: diff against this ref instead of the detected one
#   --committed        local mode: HEAD only, ignore uncommitted work
#   --no-untracked     local mode: skip new files that aren't in git yet
#   --model <name>     pass -model to meat
#   --no-cache         pass -no-cache to meat (force recompute)
#
# Prints two JSON objects, newline-separated:
#   1. target metadata — `kind` is "pr" or "local"; PR mode adds the `gh pr view`
#      fields, local mode fills the same field names from git.
#   2. meat's result (smart_diff, summary, elision, token counts)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=target.sh
. "$HERE/target.sh"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

FORCE=auto
TARGET=""
REPO=""
BASE_OVERRIDE=""
COMMITTED=no
UNTRACKED=yes
MODEL_ARG=""
MEAT_ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --local) FORCE=local; shift ;;
        --pr) FORCE=pr; TARGET="$2"; shift 2 ;;
        --repo) REPO="$2"; shift 2 ;;
        --repo=*) REPO="${1#--repo=}"; shift ;;
        --base) BASE_OVERRIDE="$2"; shift 2 ;;
        --base=*) BASE_OVERRIDE="${1#--base=}"; shift ;;
        --committed) COMMITTED=yes; shift ;;
        --no-untracked) UNTRACKED=no; shift ;;
        --model) MODEL_ARG="$2"; MEAT_ARGS+=(-model "$2"); shift 2 ;;
        --no-cache) MEAT_ARGS+=(-no-cache); shift ;;
        -*) die "unknown flag: $1 (try --help)" ;;
        *)
            [ -z "$TARGET" ] || die "unexpected extra argument: $1"
            TARGET="$1"; shift
            ;;
    esac
done

REPO_ARGS=()
if [ -n "$REPO" ]; then REPO_ARGS=(--repo "$REPO"); fi

MEAT="$(command -v meat || true)"
if [ -z "$MEAT" ]; then
    MEAT="$HOME/go/bin/meat"
    [ -x "$MEAT" ] || die "meat not found on PATH or at ~/go/bin/meat — go install meat.dev/cmd/meat@latest"
fi

# ---- credentials -------------------------------------------------------------
# meat resolves its own credentials from the environment, and every path except
# one it can work out alone. The exception is a machine whose only usable key is
# OpenRouter's: reaching OpenRouter needs an Anthropic-compatible base URL to
# point at *and* a Claude model name, because without one meat takes its OpenAI
# code path and never consults ANTHROPIC_BASE_URL/OPENROUTER_API_KEY at all. So
# arm both here — for this process only, and never over a value the caller chose.
#
# Every test spells the variable `${VAR:-}` rather than asking whether it exists:
# a Claude Code session exports ANTHROPIC_API_KEY *empty*, and an empty value is
# not a credential — treat set-but-empty exactly like unset.
if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -z "${OPENAI_API_KEY:-}" ] \
   && [ -z "${OPENAI_BASE_URL:-}" ] && [ -n "${OPENROUTER_API_KEY:-}" ]; then
    # This meat build carries a local patch (~/code/meat, meat/anthropic.go) so
    # that ANTHROPIC_BASE_URL with no ANTHROPIC_API_KEY falls back to
    # OPENROUTER_API_KEY for the x-api-key header.
    [ -n "${ANTHROPIC_BASE_URL:-}" ] || export ANTHROPIC_BASE_URL="https://openrouter.ai/api"
    if [ -z "${MEAT_MODEL:-}" ] && [ -z "$MODEL_ARG" ]; then
        export MEAT_MODEL="claude-opus-4-8"
    fi
fi

# Nothing above armed anything and meat has no credential of its own to find:
# say which variables would fix it rather than letting meat report whichever
# provider it happened to pick. `/exe.dev` is the marker meat itself stats before
# probing the managed LLM gateway, so this never blocks a VM that has one.
if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -z "${ANTHROPIC_BASE_URL:-}" ] \
   && [ -z "${OPENAI_API_KEY:-}" ] && [ -z "${OPENAI_BASE_URL:-}" ] \
   && [ ! -e /exe.dev ]; then
    die "no LLM credentials in the environment — set OPENROUTER_API_KEY (routed to OpenRouter automatically), or ANTHROPIC_API_KEY, or OPENAI_API_KEY"
fi

CLASS="$(classify_target "$TARGET")"
[ "$CLASS" != unknown ] || die "don't know what '$TARGET' names — pass a PR number/URL, a branch, or a git range"

# ---- decide PR vs local ------------------------------------------------------
# Only `auto`/`ref` needs GitHub asked, and only when nothing forced a mode. A
# missing gh, a checkout with no remote, or a branch with no PR all mean the same
# thing here — local mode — so failure to answer is not an error.
PR_JSON=""
PR_FOUND=no
PR_FIELDS=number,title,url,state,author,baseRefName,headRefName,additions,deletions,changedFiles,body

lookup_pr() {
    local t="${1-}"
    command -v gh >/dev/null 2>&1 || return 1
    if [ -n "$t" ]; then
        gh pr view "$t" ${REPO_ARGS[@]+"${REPO_ARGS[@]}"} --json "$PR_FIELDS" 2>/dev/null
    else
        gh pr view ${REPO_ARGS[@]+"${REPO_ARGS[@]}"} --json "$PR_FIELDS" 2>/dev/null
    fi
}

if [ "$FORCE" = auto ] && { [ "$CLASS" = auto ] || [ "$CLASS" = ref ]; }; then
    PR_JSON="$(lookup_pr "$TARGET" || true)"
    [ -n "$PR_JSON" ] && PR_FOUND=yes
fi

MODE="$(resolve_mode "$CLASS" "$PR_FOUND" "$FORCE")"
[ "$MODE" != unknown ] || die "could not resolve '$TARGET' to a PR or a git range"

# ---- PR mode -----------------------------------------------------------------
if [ "$MODE" = pr ]; then
    command -v gh >/dev/null 2>&1 || die "gh (GitHub CLI) not found on PATH"
    command -v jq >/dev/null 2>&1 || die "jq not found on PATH"

    if [ -z "$PR_JSON" ]; then
        PR_JSON="$(lookup_pr "$TARGET" || true)"
        [ -n "$PR_JSON" ] || die "no pull request found for '${TARGET:-the current branch}'"
    fi

    printf '%s' "$PR_JSON" | jq -c '. + {kind: "pr", range: ((.baseRefName // "") + "..." + (.headRefName // ""))}'

    if [ -n "$TARGET" ]; then
        DIFF="$(gh pr diff "$TARGET" ${REPO_ARGS[@]+"${REPO_ARGS[@]}"})"
    else
        DIFF="$(gh pr diff ${REPO_ARGS[@]+"${REPO_ARGS[@]}"})"
    fi

    [ -n "$DIFF" ] || die "empty diff — PR may have no changes or gh could not fetch it"

    printf '%s' "$DIFF" | "$MEAT" ${MEAT_ARGS[@]+"${MEAT_ARGS[@]}"} -json
    exit 0
fi

# ---- local mode --------------------------------------------------------------
git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository (and no PR to review)"
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"
git rev-parse --verify --quiet HEAD >/dev/null 2>&1 || die "repository has no commits to diff"

BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"
BASE=""
HEAD_REF=""
DOTS='..'

if [ "$CLASS" = range ]; then
    IFS=$'\t' read -r BASE HEAD_REF DOTS <<<"$(split_range "$TARGET")"
elif [ "$CLASS" = ref ] || { [ "$FORCE" = local ] && [ -n "$TARGET" ]; }; then
    # `--local <ref>`: a branch names the *head* to review, a base is what --base
    # is for. Reviewing it as a branch means diffing it against its fork point.
    HEAD_REF="$TARGET"
fi

# `--committed` means "the commits, not my scratch state", so pin the head to a
# commit before base detection — the detector's fallbacks branch on whether the
# working tree is involved, and it isn't once this is set.
if [ "$COMMITTED" = yes ] && [ -z "$HEAD_REF" ]; then
    HEAD_REF=HEAD
fi

# Detected base: reuse the /diff skill's fork-point detection rather than forking
# it — it is the one place that already handles a stale local trunk vs origin's.
detect_base_via_diff_skill() {
    local c script
    for c in "$HERE/../../diff/scripts/detect-range.sh" \
             "$HOME/.claude/skills/diff/scripts/detect-range.sh" \
             "$HOME/.agents/skills/diff/scripts/detect-range.sh" \
             "$HOME/code/skills/skills/diff/scripts/detect-range.sh"; do
        [ -f "$c" ] && { script="$c"; break; }
    done
    [ -n "${script:-}" ] || return 1
    bash "$script" 2>/dev/null \
        | awk -F'\t' '$1=="arg" && $2 !~ /^--/ {print $2; exit}'
}

# Fallback when the /diff skill isn't installed: the descendant-most merge-base
# across every spelling of the trunk. Same reasoning as detect-range.sh — a stale
# local `main` would otherwise drag in every upstream commit as if it were ours.
detect_base_fallback() {
    local names name ref base best=""
    names="$(
        git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's#^refs/remotes/origin/##'
        printf 'main\nmaster\n'
    )"
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        for ref in "origin/$name" "$name"; do
            git rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1 || continue
            base="$(git merge-base "$ref" HEAD 2>/dev/null)" || continue
            [ -n "$base" ] || continue
            if [ -z "$best" ] || { [ "$best" != "$base" ] \
                && git merge-base --is-ancestor "$best" "$base" 2>/dev/null; }; then
                best="$base"
            fi
        done
    done <<<"$names"
    [ -n "$best" ] || return 1
    printf '%s' "$best"
}

if [ -n "$BASE_OVERRIDE" ]; then
    BASE="$BASE_OVERRIDE"
elif [ -z "$BASE" ]; then
    if [ -n "$HEAD_REF" ]; then
        # An explicit head: its fork point is a merge-base against the trunk, not
        # against HEAD, so ask git directly rather than reusing the no-arg detector.
        BASE="$(detect_base_fallback || true)"
        if [ -n "$BASE" ]; then
            BASE="$(git merge-base "$BASE" "$HEAD_REF" 2>/dev/null || printf '%s' "$BASE")"
        fi
    else
        BASE="$(detect_base_via_diff_skill || true)"
        [ -n "$BASE" ] || BASE="$(detect_base_fallback || true)"
    fi
fi

# On the trunk with no branch to compare, the last commit is the review.
if [ -z "$BASE" ] || [ "$BASE" = "$(git rev-parse HEAD)" ]; then
    if [ -z "$HEAD_REF" ] && [ -n "$(git status --porcelain 2>/dev/null)" ]; then
        BASE=HEAD
    else
        BASE="$(git rev-parse --verify --quiet 'HEAD~1' || true)"
        [ -n "$BASE" ] || die "nothing to diff: HEAD is the only commit and the tree is clean"
    fi
fi

git rev-parse --verify --quiet "$BASE^{commit}" >/dev/null 2>&1 \
    || die "base '$BASE' is not a commit this repo knows"
if [ -n "$HEAD_REF" ]; then
    git rev-parse --verify --quiet "$HEAD_REF^{commit}" >/dev/null 2>&1 \
        || die "head '$HEAD_REF' is not a commit this repo knows"
fi

# New files aren't in `git diff` output at all until git knows about them, which
# would silently drop the most reviewable part of in-progress work. Register them
# as intent-to-add in a *copy* of the index so the real index is never touched.
TMPIDX=""
cleanup() { if [ -n "$TMPIDX" ]; then rm -f "$TMPIDX"; fi; }
trap cleanup EXIT

if [ -z "$HEAD_REF" ] && [ "$UNTRACKED" = yes ]; then
    GITDIR="$(git rev-parse --git-dir)"
    if [ -f "$GITDIR/index" ]; then
        TMPIDX="$(mktemp "${TMPDIR:-/tmp}/meat-index.XXXXXX")"
        if cp "$GITDIR/index" "$TMPIDX" 2>/dev/null; then
            GIT_INDEX_FILE="$TMPIDX" git add -A -N -- . >/dev/null 2>&1 || { rm -f "$TMPIDX"; TMPIDX=""; }
        else
            rm -f "$TMPIDX"; TMPIDX=""
        fi
    fi
fi

run_git_diff() {   # extra git-diff flags as "$@"; range comes from the resolved state
    if [ -n "$HEAD_REF" ]; then
        git diff "$@" "${BASE}${DOTS}${HEAD_REF}"
    elif [ -n "$TMPIDX" ]; then
        GIT_INDEX_FILE="$TMPIDX" git diff "$@" "$BASE"
    else
        git diff "$@" "$BASE"
    fi
}

DIFF="$(run_git_diff)"
[ -n "$DIFF" ] || die "empty diff for ${BASE}${DOTS}${HEAD_REF:-working tree} — nothing to review"

NUMSTAT="$(run_git_diff --numstat || true)"
read -r ADDS DELS FILES <<<"$(
    printf '%s\n' "$NUMSTAT" | awk -F'\t' '
        NF >= 3 { if ($1 != "-") a += $1; if ($2 != "-") d += $2; f++ }
        END { printf "%d %d %d", a, d, f }'
)"

RANGE="${BASE}${DOTS}${HEAD_REF:-<working tree>}"
LOG="$(git log --format='%h %s' "${BASE}..${HEAD_REF:-HEAD}" 2>/dev/null | head -50 || true)"
SLUG="$(git config --get remote.origin.url 2>/dev/null \
    | sed -E 's#^git@[^:]+:##; s#^https?://[^/]+/##; s#\.git$##' || true)"
AUTHOR="$(git config --get user.name 2>/dev/null || printf 'local')"
DIRTY=false
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then DIRTY=true; fi

jq -nc \
    --arg branch "$BRANCH" \
    --arg base "$BASE" \
    --arg head "${HEAD_REF:-<working tree>}" \
    --arg range "$RANGE" \
    --arg repo "$SLUG" \
    --arg author "$AUTHOR" \
    --arg body "$LOG" \
    --argjson adds "${ADDS:-0}" \
    --argjson dels "${DELS:-0}" \
    --argjson files "${FILES:-0}" \
    --argjson dirty "$DIRTY" \
    '{
        kind: "local",
        title: ($branch + " (" + $range + ")"),
        url: "",
        state: "LOCAL",
        author: {login: $author},
        repo: $repo,
        baseRefName: $base,
        headRefName: $head,
        range: $range,
        dirty: $dirty,
        additions: $adds,
        deletions: $dels,
        changedFiles: $files,
        body: $body
    }'

printf '%s' "$DIFF" | "$MEAT" ${MEAT_ARGS[@]+"${MEAT_ARGS[@]}"} -json
