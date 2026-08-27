#!/usr/bin/env bash
# gather.sh — Wave 0. Collect every raw input the four card writers will read,
# and decide nothing that needs a model.
#
# The waves after this one are expensive and easy to bias, so the rule is that
# anything derivable from git/gh is derived here, once, into files. If a later
# step finds itself re-deriving "which issue is this" or "what is the base", it
# is reading the wrong thing — read $WORK instead.
#
# Usage:
#   gather.sh [<pr-url|pr-number|branch>] [--repo owner/name] [--repo-path <dir>]
#             [--work <dir>] [--base <ref>] [--head <ref>]
#
# Degrades on purpose: with no `gh`, or on a repo it cannot reach, it falls back
# to git alone and reports what is missing rather than failing. A missing input
# is a fact the verdict rule knows how to handle (N1); a crashed collector is not.
#
# Output: eval-safe KEY='value' lines (see EMITTED KEYS at the bottom).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=extract.sh
. "$HERE/extract.sh"

LIB="$HERE/../../local-pr-review/scripts/lib.sh"
if [ -f "$LIB" ]; then
    # shellcheck source=/dev/null
    . "$LIB"
else
    sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
    emit() { printf "%s=%s\n" "$1" "$(sq "${2-}")"; }
    die() { printf 'error: %s\n' "$*" >&2; exit 1; }
    slugify() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]\{1,\}/-/g; s/^-//; s/-$//'; }
    default_branch() {
        local b
        b="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
        [ -n "$b" ] && { printf '%s\n' "$b"; return; }
        for b in main master; do
            git rev-parse --verify --quiet "$b^{commit}" >/dev/null 2>&1 && { printf '%s\n' "$b"; return; }
        done
        printf 'main\n'
    }
fi

TARGET=""; REPO_ARG=""; REPO_PATH=""; WORK=""; BASE_IN=""; HEAD_IN=""
while [ $# -gt 0 ]; do
    case "$1" in
        --repo)      REPO_ARG="$2"; shift 2 ;;
        --repo-path) REPO_PATH="$2"; shift 2 ;;
        --work)      WORK="$2"; shift 2 ;;
        --base)      BASE_IN="$2"; shift 2 ;;
        --head)      HEAD_IN="$2"; shift 2 ;;
        -*)          die "unknown flag: $1" ;;
        *)           TARGET="$1"; shift ;;
    esac
done

if [ -n "$REPO_PATH" ]; then cd "$REPO_PATH"; fi
git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository (use --repo-path)"

UNAVAILABLE=()
note_missing() { UNAVAILABLE+=("$1"); }

# ---- who and what ----------------------------------------------------------
# pr-context.sh already encodes PR-vs-branch and the author classification the
# whole skills repo agrees on, so reuse it rather than re-deriving a second,
# subtly different answer here.
PR_JSON='{}'; PR_NUMBER=""; PR_TITLE=""; PR_URL=""; PR_BODY=""
BASE_REF=""; HEAD_REF=""; AUTHOR_CLASS=""; REPO=""
PRCTX="$HERE/../../local-pr-review/scripts/pr-context.sh"
if [ -f "$PRCTX" ] && command -v gh >/dev/null 2>&1; then
    CTX="$("$PRCTX" ${REPO_ARG:+--repo "$REPO_ARG"} ${TARGET:+"$TARGET"} 2>/dev/null || true)"
    if [ -n "$CTX" ]; then
        eval "$CTX"
        PR_NUMBER="${PR_NUMBER:-}"; PR_TITLE="${PR_TITLE:-}"; PR_URL="${PR_URL:-}"
        BASE_REF="${BASE_REF:-}"; HEAD_REF="${HEAD_REF:-}"; AUTHOR_CLASS="${AUTHOR_CLASS:-}"
        REPO="${REPO:-}"
    fi
fi
if [ -n "$PR_NUMBER" ] && command -v gh >/dev/null 2>&1; then
    PR_JSON="$(gh pr view "$PR_NUMBER" ${REPO_ARG:+--repo "$REPO_ARG"} \
        --json number,title,url,body,baseRefName,headRefName,headRefOid,author,labels,commits \
        2>/dev/null || echo '{}')"
    PR_BODY="$(printf '%s' "$PR_JSON" | jq -r '.body // ""')"
fi

# ---- the range -------------------------------------------------------------
# Against the merge-base, never the base branch's moving tip: otherwise every
# commit that landed on master since this branch forked shows up as part of the
# change under review, and the change card describes work nobody in this PR did.
HEAD_SHA="${HEAD_IN:-}"
[ -n "$HEAD_SHA" ] || HEAD_SHA="${HEAD_SHA:-$(git rev-parse HEAD 2>/dev/null || true)}"
BASE_TIP="${BASE_IN:-}"
if [ -z "$BASE_TIP" ]; then
    if [ -n "$BASE_REF" ]; then
        BASE_TIP="$(git rev-parse --verify --quiet "origin/$BASE_REF" 2>/dev/null || \
                    git rev-parse --verify --quiet "$BASE_REF" 2>/dev/null || true)"
    fi
    [ -n "$BASE_TIP" ] || BASE_TIP="$(git rev-parse --verify --quiet "origin/$(default_branch)" 2>/dev/null || \
                                      git rev-parse --verify --quiet "$(default_branch)" 2>/dev/null || true)"
fi
BASE_SHA=""
if [ -n "$BASE_TIP" ] && [ -n "$HEAD_SHA" ]; then
    BASE_SHA="$(git merge-base "$BASE_TIP" "$HEAD_SHA" 2>/dev/null || true)"
fi
[ -n "$BASE_SHA" ] || BASE_SHA="$(git rev-parse --verify --quiet "${HEAD_SHA}^" 2>/dev/null || true)"

# ---- where the collected inputs land ---------------------------------------
if [ -z "$WORK" ]; then
    WORK="${XDG_CACHE_HOME:-$HOME/.cache}/autofix-review/$(slugify "${REPO:-local}")/$(slugify "${HEAD_SHA:-head}")"
fi
mkdir -p "$WORK"/{cards,links,probes,refutations,raw}

DIFF=""
if [ -n "$BASE_SHA" ] && [ -n "$HEAD_SHA" ]; then
    DIFF="$(git diff "$BASE_SHA" "$HEAD_SHA" 2>/dev/null || true)"
fi
if [ -z "$DIFF" ]; then
    note_missing diff
else
    printf '%s\n' "$DIFF" > "$WORK/raw/diff.patch"
fi

COMMITS=""
if [ -n "$BASE_SHA" ] && [ -n "$HEAD_SHA" ]; then
    COMMITS="$(git log --format='%H%n%s%n%b%n---' "$BASE_SHA".."$HEAD_SHA" 2>/dev/null || true)"
fi

# ---- body.md: everything the author said about this change ------------------
# One file, because `intent` is the only card that reads it and it must read all
# of it: a claim made only in a commit message is still a claim.
{
    [ -n "$PR_TITLE" ] && printf '# %s\n\n' "$PR_TITLE"
    if [ -n "$PR_BODY" ]; then
        printf '## Pull request description\n\n%s\n\n' "$PR_BODY"
    fi
    printf '## Commit messages\n\n'
    printf '%s\n' "${COMMITS:-_(none)_}"
} > "$WORK/raw/body.md"

ALL_TEXT="$PR_TITLE
$PR_BODY
$COMMITS
${HEAD_REF:-}"

# ---- the derived facts ------------------------------------------------------
parse_issue_refs "$ALL_TEXT" > "$WORK/raw/issue-refs.txt" || true
REF_COUNT="$(wc -l < "$WORK/raw/issue-refs.txt" | tr -d ' ')"

printf '%s' "$DIFF" | lint_signals > "$WORK/raw/lint.txt" || true
LINT_COUNT="$(wc -l < "$WORK/raw/lint.txt" | tr -d ' ')"

printf '%s' "$DIFF" | changed_files > "$WORK/raw/files.txt" || true
FILE_COUNT="$(wc -l < "$WORK/raw/files.txt" | tr -d ' ')"

body_evidence "$ALL_TEXT" > "$WORK/raw/body-evidence.txt" || true
BODY_EV_COUNT="$(wc -l < "$WORK/raw/body-evidence.txt" | tr -d ' ')"

MODE="$(classify_mode "$PR_TITLE $COMMITS ${HEAD_REF:-}" "$LINT_COUNT" "$REF_COUNT")"

# Where the evidence card will have to come from. A tracker issue is the strong
# case; the description is the weaker one (the author wrote both the evidence and
# the intent, so they are not independent); nothing is N1.
if [ "$REF_COUNT" -gt 0 ]; then EVIDENCE_SOURCE=issue
elif [ "$BODY_EV_COUNT" -gt 0 ]; then EVIDENCE_SOURCE=pr-body
else EVIDENCE_SOURCE=none
fi

# Only docs that actually exist, so the standards scout is handed a reading list
# rather than a guessing game.
: > "$WORK/raw/repo-docs.txt"
if [ "$FILE_COUNT" -gt 0 ]; then
    # shellcheck disable=SC2046
    doc_candidates $(cat "$WORK/raw/files.txt") | while read -r c; do
        if [ -e "$c" ]; then printf '%s\n' "$c"; fi
    done >> "$WORK/raw/repo-docs.txt"
fi
DOC_COUNT="$(wc -l < "$WORK/raw/repo-docs.txt" | tr -d ' ')"

# A bug fix with nothing to check against is the one gap worth reporting up
# front: it is what routes the verdict to N1 instead of letting a later wave
# review the diff against an imagined issue. A description that states the bug
# and its cause counts — weakly, but it counts.
if [ "$EVIDENCE_SOURCE" = none ] && [ "$MODE" = bugfix ]; then note_missing issue; fi

jq -n \
    --arg repo "${REPO:-}" --arg pr "${PR_NUMBER:-}" --arg title "${PR_TITLE:-}" \
    --arg url "${PR_URL:-}" --arg base "$BASE_SHA" --arg head "$HEAD_SHA" \
    --arg base_ref "${BASE_REF:-}" --arg head_ref "${HEAD_REF:-}" \
    --arg class "${AUTHOR_CLASS:-}" --arg mode "$MODE" --arg work "$WORK" \
    --arg evsrc "$EVIDENCE_SOURCE" --arg repo_path "$(pwd)" \
    --argjson unavailable "$(printf '%s\n' "${UNAVAILABLE[@]+"${UNAVAILABLE[@]}"}" | jq -R . | jq -s 'map(select(. != ""))')" \
    '{repo:$repo, pr:$pr, title:$title, url:$url, base_sha:$base, head_sha:$head,
      base_ref:$base_ref, head_ref:$head_ref, author_class:$class, mode:$mode,
      work:$work, repo_path:$repo_path, evidence_source:$evsrc,
      unavailable:$unavailable}' > "$WORK/meta.json"

emit WORK          "$WORK"
emit MODE          "$MODE"
emit REPO          "${REPO:-}"
emit PR_NUMBER     "${PR_NUMBER:-}"
emit PR_TITLE      "${PR_TITLE:-}"
emit PR_URL        "${PR_URL:-}"
emit AUTHOR_CLASS  "${AUTHOR_CLASS:-}"
emit BASE_SHA      "$BASE_SHA"
emit HEAD_SHA      "$HEAD_SHA"
emit BASE_REF      "${BASE_REF:-}"
emit HEAD_REF      "${HEAD_REF:-}"
emit DIFF_FILE     "$WORK/raw/diff.patch"
emit BODY_FILE     "$WORK/raw/body.md"
emit REFS_FILE     "$WORK/raw/issue-refs.txt"
emit LINT_FILE     "$WORK/raw/lint.txt"
emit BODY_EV_FILE  "$WORK/raw/body-evidence.txt"
emit EVIDENCE_SOURCE "$EVIDENCE_SOURCE"
emit FILES_FILE    "$WORK/raw/files.txt"
emit DOCS_FILE     "$WORK/raw/repo-docs.txt"
emit META_FILE     "$WORK/meta.json"
emit REF_COUNT     "$REF_COUNT"
emit LINT_COUNT    "$LINT_COUNT"
emit FILE_COUNT    "$FILE_COUNT"
emit DOC_COUNT     "$DOC_COUNT"
emit UNAVAILABLE   "$(printf '%s' "${UNAVAILABLE[*]+"${UNAVAILABLE[*]}"}")"

# EMITTED KEYS
#   WORK         collection root; every later wave reads and writes under here
#   MODE         bugfix | lintfix — which chain gets built
#   BASE_SHA     the merge-base, not the base branch tip
#   DIFF_FILE    the only file the `change` card writer may read
#   BODY_FILE    the only file the `intent` card writer may read
#   REFS_FILE    kind<TAB>ref — what the `evidence` writer goes and fetches
#   EVIDENCE_SOURCE  issue | pr-body | none — where evidence has to come from
#   BODY_EV_FILE embedded evidence found in the description, when there is no issue
#   LINT_FILE    kind<TAB>detail — suppression and lint-config signals
#   DOCS_FILE    repo guidance that exists and governs the changed files
#   UNAVAILABLE  space-separated inputs that could not be read; drives N1
