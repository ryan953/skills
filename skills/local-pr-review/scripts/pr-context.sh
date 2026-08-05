#!/usr/bin/env bash
# pr-context.sh — resolve what is being reviewed and who wrote it, in one call.
#
# Answers the questions the flow branches on, so the model never has to infer
# them from prose:
#   1. Is there a PR for this, or is it a local branch (pushed or not)?
#   2. Did I write it, did a bot, or did another human?
#   3. Therefore: description pane? review panes? annotations -> GitHub or edits?
#      iterate loop allowed?
#
# Usage:
#   pr-context.sh                     # PR for the current branch, else branch mode
#   pr-context.sh <pr-url-or-number>  # that PR
#   pr-context.sh <branch-name>       # that branch's PR, else branch mode
#   pr-context.sh --repo owner/name <pr>
#
# Output: eval-safe KEY='value' lines (see EMITTED KEYS at the bottom).
# Run from inside the repo checkout.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
# shellcheck source=classify.sh
. "$HERE/classify.sh"

command -v gh >/dev/null 2>&1 || die "gh (GitHub CLI) not found on PATH"
git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"

REPO_ARGS=()
TARGET=""
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) REPO_ARGS=(--repo "$2"); shift 2 ;;
        --repo=*) REPO_ARGS=(--repo "${1#--repo=}"); shift ;;
        -*) die "unknown flag: $1" ;;
        *) TARGET="$1"; shift ;;
    esac
done

FIELDS=number,title,url,author,isDraft,state,baseRefName,headRefName,headRefOid,additions,deletions,changedFiles,labels,body,mergeable,reviewDecision

# `gh pr view` with no target resolves the PR for the current branch and fails
# when there is none — that failure is the signal for branch mode, not an error.
# A named target that isn't a PR (a bare branch name) gets the same treatment,
# so "review branch foo" works whether or not foo was ever pushed.
PR_JSON=""
if [ -n "$TARGET" ]; then
    PR_JSON="$(gh pr view "$TARGET" "${REPO_ARGS[@]}" --json "$FIELDS" 2>/dev/null || true)"
else
    PR_JSON="$(gh pr view "${REPO_ARGS[@]}" --json "$FIELDS" 2>/dev/null || true)"
fi

ME="$(gh api user --jq .login 2>/dev/null || true)"
REPO="$(gh repo view "${REPO_ARGS[@]}" --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"
TMP="$(job_tmp)"

if [ -n "$PR_JSON" ]; then
    KIND=pr
    HAS_PR=yes
    jqv() { printf '%s' "$PR_JSON" | jq -r "$1 // empty"; }
    PR_NUMBER="$(jqv .number)"
    PR_TITLE="$(jqv .title)"
    PR_URL="$(jqv .url)"
    PR_STATE="$(jqv .state)"
    PR_DRAFT="$(printf '%s' "$PR_JSON" | jq -r '.isDraft // false')"
    BASE_REF="$(jqv .baseRefName)"
    HEAD_REF="$(jqv .headRefName)"
    HEAD_SHA="$(jqv .headRefOid)"
    ADDITIONS="$(printf '%s' "$PR_JSON" | jq -r '.additions // 0')"
    DELETIONS="$(printf '%s' "$PR_JSON" | jq -r '.deletions // 0')"
    CHANGED="$(printf '%s' "$PR_JSON" | jq -r '.changedFiles // 0')"
    LOGIN="$(jqv .author.login)"
    IS_BOT="$(printf '%s' "$PR_JSON" | jq -r '.author.is_bot // false')"
    LABELS="$(printf '%s' "$PR_JSON" | jq -r '[.labels[]?.name] | join(",")')"
    PUSHED=yes
else
    # No PR: reviewing a local branch. Nothing to post to, and the work is mine.
    KIND=branch
    HAS_PR=no
    PR_NUMBER=""; PR_TITLE=""; PR_URL=""; PR_STATE=""; PR_DRAFT=false
    BASE_REF=""
    HEAD_REF="${TARGET:-$BRANCH}"
    HEAD_SHA="$(git rev-parse "$HEAD_REF" 2>/dev/null || git rev-parse HEAD 2>/dev/null || true)"
    ADDITIONS=0; DELETIONS=0; CHANGED=0; LABELS=""
    LOGIN="$ME"; IS_BOT=false
    # Pushed-but-no-PR vs never-pushed changes nothing about routing (there is
    # still no PR to comment on) but it is the difference between "open a PR
    # when you're happy" and "push first", so report it.
    if git rev-parse --verify --quiet "refs/remotes/origin/$HEAD_REF" >/dev/null 2>&1; then
        PUSHED=yes
    else
        PUSHED=no
    fi
fi

CLASS="$(classify_author "$ME" "$LOGIN" "$IS_BOT" "$HEAD_REF")"
# A branch with no PR is my own working copy no matter what the last commit's
# author says, so don't let a bot-prefixed branch name route it as a bot PR.
[ "$HAS_PR" = yes ] || CLASS=mine

DESC_PANE="$(wants_desc_pane "$CLASS")"
REVIEW_PANES="$(wants_review_panes "$CLASS")"
ROUTE="$(annotation_route "$CLASS" "$HAS_PR")"
ITERATE="$(iterate_ok "$CLASS")"

# Cache + state keyed on the head SHA: review findings describe that exact tree,
# so the next push misses the cache instead of resurrecting a stale review.
CACHE_DIR="$(cache_dir "${REPO:-local}" "${HEAD_SHA:-$BRANCH}")"
STATE="$CACHE_DIR/session.state"

# Description file for the top pane: title/author/stats header plus the PR body,
# written even when no pane wants it so the model can read it cheaply.
DESC_FILE=""
if [ "$HAS_PR" = yes ]; then
    DESC_FILE="$CACHE_DIR/pr-description.md"
    {
        printf '# #%s %s\n\n' "$PR_NUMBER" "$PR_TITLE"
        printf -- '- author: **%s** (%s)\n' "$LOGIN" "$CLASS"
        printf -- '- %s -> %s%s\n' "$HEAD_REF" "$BASE_REF" \
            "$([ "$PR_DRAFT" = true ] && printf ' _(draft)_' || true)"
        printf -- '- +%s / -%s across %s file(s)\n' "$ADDITIONS" "$DELETIONS" "$CHANGED"
        [ -n "$LABELS" ] && printf -- '- labels: %s\n' "$LABELS"
        printf -- '- %s\n\n---\n\n' "$PR_URL"
        printf '%s\n' "$PR_JSON" | jq -r '.body // "_(no description)_"'
    } > "$DESC_FILE"
fi

emit KIND         "$KIND"
emit HAS_PR       "$HAS_PR"
emit PUSHED       "$PUSHED"
emit REPO         "$REPO"
emit ME           "$ME"
emit BRANCH       "$BRANCH"
emit PR_NUMBER    "$PR_NUMBER"
emit PR_TITLE     "$PR_TITLE"
emit PR_URL       "$PR_URL"
emit PR_STATE     "$PR_STATE"
emit PR_DRAFT     "$PR_DRAFT"
emit BASE_REF     "$BASE_REF"
emit HEAD_REF     "$HEAD_REF"
emit HEAD_SHA     "$HEAD_SHA"
emit ADDITIONS    "$ADDITIONS"
emit DELETIONS    "$DELETIONS"
emit CHANGED      "$CHANGED"
emit LABELS       "$LABELS"
emit AUTHOR_LOGIN "$LOGIN"
emit AUTHOR_IS_BOT "$IS_BOT"
emit AUTHOR_CLASS "$CLASS"
emit DESC_PANE    "$DESC_PANE"
emit REVIEW_PANES "$REVIEW_PANES"
emit ROUTE        "$ROUTE"
emit ITERATE      "$ITERATE"
emit DESC_FILE    "$DESC_FILE"
emit CACHE_DIR    "$CACHE_DIR"
emit STATE        "$STATE"

# EMITTED KEYS
#   KIND          pr | branch
#   HAS_PR        yes | no          — is there anywhere to post comments?
#   PUSHED        yes | no          — does origin have this branch at all?
#   AUTHOR_CLASS  mine | bot | other
#   DESC_PANE     yes | no          — put the PR description in its own pane
#   REVIEW_PANES  yes | no          — show review outputs in panes vs. act on them
#   ROUTE         apply | comment   — what revdiff annotations become
#   ITERATE       yes | no          — is the fix-and-re-review loop allowed
#   DESC_FILE     rendered markdown for the description pane ('' when no PR)
#   CACHE_DIR     per-head-SHA cache for review outputs + session state
#   STATE         KEY='value' file the window/pane/post scripts read and update
