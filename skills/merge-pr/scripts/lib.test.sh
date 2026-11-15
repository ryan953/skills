#!/usr/bin/env bash
# Tests for the pure decision functions in lib.sh. No network.
#
# Run:  skills/merge-pr/scripts/lib.test.sh
# Exit: 0 all pass, 1 any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

PASS=0
FAIL=0

# eq <name> <expected> <actual>
eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        PASS=$((PASS+1)); printf '  ok   %s\n' "$name"
    else
        FAIL=$((FAIL+1))
        printf '  FAIL %s\n       expected: [%s]\n       actual:   [%s]\n' \
            "$name" "$expected" "$actual"
    fi
}

echo "parse_target"
eq "URL"          "getsentry sentry 123" "$(parse_target https://github.com/getsentry/sentry/pull/123)"
eq "owner/name#N" "getsentry sentry 123" "$(parse_target 'getsentry/sentry#123')"
eq "number+repo"  "getsentry sentry 123" "$(parse_target 123 getsentry/sentry)"
eq "branch"       ""                     "$(parse_target feat/x)"

echo "next_step / stop_reason"
eq "open, ready"   ask  "$(next_step OPEN false no)"
eq "draft"         stop "$(next_step OPEN true no)"
eq "merged"        stop "$(next_step MERGED false no)"
eq "draft reason"  "PR is a draft; mark it ready for review first." "$(stop_reason OPEN true)"
eq "closed reason" "PR is closed, not open." "$(stop_reason CLOSED false)"
eq "no reason"     ""   "$(stop_reason OPEN false)"

echo "merge_choice <ci> <merge_state> <auto_allowed>"
eq "green + clean"          merge-now "$(merge_choice green CLEAN true)"
eq "no checks + clean"      merge-now "$(merge_choice none CLEAN true)"
eq "pending"                automerge "$(merge_choice pending BLOCKED true)"
eq "needs review"           automerge "$(merge_choice green BLOCKED true)"
eq "no automerge allowed"   merge-now "$(merge_choice pending BLOCKED false)"

echo "recommend <unresolved> <ci> <merge_state> <auto_allowed> <review>"
eq "clean"                 merge-now "$(recommend 0 green CLEAN true APPROVED)"
eq "pending"               automerge "$(recommend 0 pending BLOCKED true APPROVED)"
eq "threads open"          not-now   "$(recommend 2 green CLEAN true APPROVED)"
eq "failing"               not-now   "$(recommend 0 failing UNSTABLE true APPROVED)"
eq "changes requested"     not-now   "$(recommend 0 green BLOCKED true CHANGES_REQUESTED)"
eq "conflicts"             not-now   "$(recommend 0 green DIRTY true APPROVED)"
eq "blocked, no automerge" not-now   "$(recommend 0 pending BLOCKED false APPROVED)"

echo "merge_options"
eq "recommended first" "automerge,not-now" "$(merge_options automerge automerge)"
eq "not-now first"     "not-now,merge-now" "$(merge_options not-now merge-now)"

echo "blockers"
eq "none" "" "$(blockers green '' 0 APPROVED CLEAN)"
eq "several" \
    "$(printf 'CI failing: lint, test\n1 unresolved review thread(s)\nNeeds an approving review\nBranch is behind its base')" \
    "$(blockers failing 'lint, test' 1 REVIEW_REQUIRED BEHIND)"

echo ""
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
