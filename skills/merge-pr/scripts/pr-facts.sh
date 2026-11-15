#!/usr/bin/env bash
# pr-facts.sh — everything merge-pr needs to ask its one question, in one
# read-only pass. Never merges; apply.sh does that, and calls this first so it
# acts on fresh facts.
#
# Usage:
#   pr-facts.sh [<pr>] [--repo owner/name]
#
# <pr> is a number, #number, owner/name#number, URL, or branch. With none it uses
# the current branch's PR.
#
# Output: eval-safe KEY='value' lines (see the emit calls at the bottom).

# GraphQL and jq variables ($owner) are meant for those tools, not the shell.
# shellcheck disable=SC2016

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

command -v gh >/dev/null 2>&1 || die "gh (GitHub CLI) not found on PATH"
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"

REPO_ARG=""
TARGET=""
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) REPO_ARG="$2"; shift 2 ;;
        -*) die "unknown flag: $1" ;;
        *) TARGET="$1"; shift ;;
    esac
done

PARSED="$(parse_target "$TARGET" "$REPO_ARG")"
if [ -z "$PARSED" ]; then
    URL="$(gh pr view ${TARGET:+"${TARGET#\#}"} ${REPO_ARG:+--repo "$REPO_ARG"} --json url -q .url)" \
        || die "no PR found for '${TARGET:-current branch}'"
    PARSED="$(parse_target "$URL")"
fi
read -r OWNER NAME NUMBER <<<"$PARSED"

CHECKS_FILE="$(mktemp)"
trap 'rm -f "$CHECKS_FILE"' EXIT
{ gh pr checks "$NUMBER" --repo "$OWNER/$NAME" --json name,bucket 2>/dev/null || printf '[]'; } \
    > "$CHECKS_FILE" &
CHECKS_PID=$!

QUERY='query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    nameWithOwner autoMergeAllowed squashMergeAllowed mergeCommitAllowed rebaseMergeAllowed
    pullRequest(number: $number) {
      number title url state isDraft mergeStateStatus reviewDecision headRefOid
      author { login }
      autoMergeRequest { mergeMethod }
      reviewThreads(first: 100) { nodes { isResolved } }
    }
  }
}'
RAW="$(gh api graphql -F owner="$OWNER" -F name="$NAME" -F number="$NUMBER" -f query="$QUERY")" \
    || die "could not load $OWNER/$NAME#$NUMBER"
DATA="$(printf '%s' "$RAW" | jq '.data.repository')"
pr() { printf '%s' "$DATA" | jq -r ".pullRequest | $1"; }
repo() { printf '%s' "$DATA" | jq -r "$1"; }

STATE="$(pr .state)"
IS_DRAFT="$(pr .isDraft)"
MERGE_STATE="$(pr .mergeStateStatus)"
REVIEW="$(pr '.reviewDecision // ""')"
MERGE_METHOD="$(repo 'if .squashMergeAllowed then "squash" elif .mergeCommitAllowed then "merge" elif .rebaseMergeAllowed then "rebase" else "" end')"
AUTO_MERGE_ALLOWED="$(repo .autoMergeAllowed)"
AUTO_MERGE_ON="$(pr 'if .autoMergeRequest then "yes" else "no" end')"
UNRESOLVED="$(pr '.reviewThreads.nodes | map(select(.isResolved | not)) | length')"

wait "$CHECKS_PID" || true
CHECKS="$(cat "$CHECKS_FILE")"
count() { printf '%s' "$CHECKS" | jq "map(select(.bucket == \"$1\")) | length"; }
CI_FAILING="$(printf '%s' "$CHECKS" | jq -r 'map(select(.bucket == "fail" or .bucket == "cancel") | .name) | join(", ")')"
CI_STATE="$(ci_state "$(printf '%s' "$CHECKS" | jq length)" "$(count fail)" "$(count cancel)" "$(count pending)")"

CHOICE="$(merge_choice "$CI_STATE" "$MERGE_STATE" "$AUTO_MERGE_ALLOWED")"
RECOMMEND="$(recommend "$UNRESOLVED" "$CI_STATE" "$MERGE_STATE" "$AUTO_MERGE_ALLOWED" "$REVIEW")"

emit REPO               "$(repo .nameWithOwner)"
emit PR_NUMBER          "$NUMBER"
emit PR_TITLE           "$(pr .title)"
emit PR_URL             "$(pr .url)"
emit AUTHOR             "$(pr '.author.login // "ghost"')"
emit PR_STATE           "$STATE"
emit IS_DRAFT           "$IS_DRAFT"
emit HEAD_SHA           "$(pr .headRefOid)"
emit NEXT               "$(next_step "$STATE" "$IS_DRAFT" "$AUTO_MERGE_ON")"
emit STOP_REASON        "$(stop_reason "$STATE" "$IS_DRAFT")"
emit MERGE_STATE        "$MERGE_STATE"
emit MERGE_METHOD       "$MERGE_METHOD"
emit AUTO_MERGE_ALLOWED "$AUTO_MERGE_ALLOWED"
emit AUTO_MERGE_ON      "$AUTO_MERGE_ON"
emit CI_STATE           "$CI_STATE"
emit RECOMMEND          "$RECOMMEND"
emit MERGE_OPTIONS      "$(merge_options "$RECOMMEND" "$CHOICE")"
emit BLOCKERS           "$(blockers "$CI_STATE" "$CI_FAILING" "$UNRESOLVED" "$REVIEW" "$MERGE_STATE")"
