#!/usr/bin/env bash
# pr-facts.sh — everything approve-pr needs to decide its next step, in one
# read-only pass. Never approves, labels, or merges; approve.sh and merge.sh do
# that, and both call this first so they act on fresh facts.
#
# Usage:
#   pr-facts.sh [<pr-number-or-url>] [--repo owner/name] [--label-added]
#
# With no PR argument it uses the current branch's PR. --label-added is for
# approve.sh: the label it just added queued new checks that may not be listed
# yet, so CI counts as pending whatever `gh pr checks` says.
#
# Output: eval-safe KEY='value' lines (see the emit calls at the bottom).

# GraphQL and jq variables ($owner, $c) are meant for those tools, not the shell.
# shellcheck disable=SC2016

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

command -v gh >/dev/null 2>&1 || die "gh (GitHub CLI) not found on PATH"
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"

REPO_ARGS=()
TARGET=""
LABEL_ADDED=no
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) REPO_ARGS=(--repo "$2"); shift 2 ;;
        --label-added) LABEL_ADDED=yes; shift ;;
        -*) die "unknown flag: $1" ;;
        *) TARGET="$1"; shift ;;
    esac
done

# `gh pr view` resolves a number, URL, or branch (or the current branch), so let
# it pick the PR and read owner/name back off the URL.
URL="$(gh pr view ${TARGET:+"$TARGET"} ${REPO_ARGS[0]+"${REPO_ARGS[@]}"} --json url -q .url)" \
    || die "no PR found for '${TARGET:-current branch}'"
OWNER="$(printf '%s' "$URL" | cut -d/ -f4)"
NAME="$(printf '%s' "$URL" | cut -d/ -f5)"
NUMBER="$(printf '%s' "$URL" | cut -d/ -f7)"
ME="$(gh api user -q .login)"

QUERY='query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    nameWithOwner autoMergeAllowed squashMergeAllowed mergeCommitAllowed rebaseMergeAllowed
    pullRequest(number: $number) {
      number title url state isDraft headRefName mergeStateStatus reviewDecision
      author { __typename login }
      labels(first: 50) { nodes { name } }
      autoMergeRequest { mergeMethod }
      latestOpinionatedReviews(first: 100) { nodes { author { login } state } }
      reviewThreads(first: 100) {
        nodes { isResolved isOutdated path line
          comments(first: 1) { nodes { author { login } body url } } }
      }
    }
  }
}'
DATA="$(gh api graphql -F owner="$OWNER" -F name="$NAME" -F number="$NUMBER" -f query="$QUERY" \
    | jq '.data.repository')"
pr() { printf '%s' "$DATA" | jq -r ".pullRequest | $1"; }
repo() { printf '%s' "$DATA" | jq -r "$1"; }

REPO="$(repo .nameWithOwner)"
LOGIN="$(pr .author.login)"
STATE="$(pr .state)"
CLASS="$(classify_author "$ME" "$LOGIN" "$(pr .author.__typename)" "$(pr .headRefName)")"

# A dismissed approval reads as DISMISSED here, so it counts as not approved.
MY_APPROVAL="$(printf '%s' "$DATA" | jq -r --arg me "$ME" \
    '[.pullRequest.latestOpinionatedReviews.nodes[] | select(.author.login == $me and .state == "APPROVED")]
     | if length > 0 then "yes" else "no" end')"

# Only sentry has the getsentry dispatch workflow behind this label.
TEST_LABEL="Trigger: getsentry tests"
IS_SENTRY=no
[ "$REPO" = getsentry/sentry ] && IS_SENTRY=yes
HAS_TEST_LABEL="$(pr '.labels.nodes | map(.name) | if index("'"$TEST_LABEL"'") then "yes" else "no" end')"

# First allowed method in squash > merge > rebase order; sentry is squash-only.
MERGE_METHOD="$(repo 'if .squashMergeAllowed then "squash" elif .mergeCommitAllowed then "merge" elif .rebaseMergeAllowed then "rebase" else "" end')"
AUTO_MERGE_ALLOWED="$(repo .autoMergeAllowed)"
MERGE_STATE="$(pr .mergeStateStatus)"

CHECKS="$(gh pr checks "$NUMBER" --repo "$REPO" --json name,bucket 2>/dev/null || printf '[]')"
count() { printf '%s' "$CHECKS" | jq "map(select(.bucket == \"$1\")) | length"; }
CI_PASS="$(count pass)"
CI_FAIL="$(count fail)"
CI_PENDING="$(count pending)"
CI_SKIPPING="$(count skipping)"
CI_CANCEL="$(count cancel)"
CI_FAILING="$(printf '%s' "$CHECKS" | jq -r 'map(select(.bucket == "fail" or .bucket == "cancel") | .name) | join(", ")')"
CI_STATE="$(ci_state "$(printf '%s' "$CHECKS" | jq length)" "$CI_FAIL" "$CI_CANCEL" "$CI_PENDING")"
if [ "$LABEL_ADDED" = yes ] && [ "$CI_STATE" != failing ]; then CI_STATE=pending; fi

# Outdated threads stay in the list: an unresolved comment on a line that has
# since moved may still be unanswered.
THREADS="$(pr '.reviewThreads.nodes | map(select(.isResolved | not)) | .[]
    | .comments.nodes[0] as $c
    | "- \(.path):\(.line // "?") @\($c.author.login // "ghost")\(if .isOutdated then " (outdated)" else "" end): \($c.body | gsub("\\s+"; " ") | .[0:120]) \($c.url)"')"
UNRESOLVED="$(pr '.reviewThreads.nodes | map(select(.isResolved | not)) | length')"

RECOMMEND="$(recommend "$UNRESOLVED" "$CI_STATE" "$MERGE_STATE" "$AUTO_MERGE_ALLOWED")"

emit REPO               "$REPO"
emit PR_NUMBER          "$NUMBER"
emit PR_TITLE           "$(pr .title)"
emit PR_URL             "$(pr .url)"
emit PR_STATE           "$STATE"
emit IS_DRAFT           "$(pr .isDraft)"
emit AUTHOR             "$LOGIN"
emit AUTHOR_CLASS       "$CLASS"
emit MY_APPROVAL        "$MY_APPROVAL"
emit NEXT               "$(next_step "$STATE" "$CLASS" "$MY_APPROVAL")"
emit STOP_REASON        "$(stop_reason "$STATE" "$CLASS" "$MY_APPROVAL")"
emit IS_SENTRY          "$IS_SENTRY"
emit TEST_LABEL         "$TEST_LABEL"
emit HAS_TEST_LABEL     "$HAS_TEST_LABEL"
emit MERGE_STATE        "$MERGE_STATE"
emit MERGE_METHOD       "$MERGE_METHOD"
emit AUTO_MERGE_ALLOWED "$AUTO_MERGE_ALLOWED"
emit AUTO_MERGE_ON      "$(pr 'if .autoMergeRequest then "yes" else "no" end')"
emit CI_STATE           "$CI_STATE"
emit UNRESOLVED_THREADS "$UNRESOLVED"
emit RECOMMEND          "$RECOMMEND"
emit MERGE_OPTIONS      "$(merge_options "$RECOMMEND" "$AUTO_MERGE_ALLOWED")"
emit SUMMARY            "$(summary "$CI_STATE" "$CI_PASS" "$CI_FAIL" "$CI_PENDING" "$CI_SKIPPING" \
                            "$CI_FAILING" "$UNRESOLVED" "$THREADS" "$LABEL_ADDED")"
