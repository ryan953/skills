#!/usr/bin/env bash
# Tests for the pure decision functions in lib.sh. No network, so every branch of
# the approve and merge routing is cheap to assert.
#
# Run:  skills/approve-pr/scripts/lib.test.sh
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

echo "classify_author"
eq "my login wins over bot branch"  mine  "$(classify_author me me User seer/fix/x)"
eq "GitHub App author"              bot   "$(classify_author me sentry Bot main)"
eq "[bot] login"                    bot   "$(classify_author me 'renovate[bot]' User x)"
eq "automation user account"        bot   "$(classify_author me seer-by-sentry User x)"
eq "bot branch prefix"              bot   "$(classify_author me someone User autofix/x)"
eq "another human"                  other "$(classify_author me someone User feat/x)"

echo "next_step"
eq "closed PR stops"                stop         "$(next_step CLOSED bot no)"
eq "merged PR stops"                stop         "$(next_step MERGED other no)"
eq "my own PR stops"                stop         "$(next_step OPEN mine no)"
eq "bot, not approved"              ask-comment  "$(next_step OPEN bot no)"
eq "human, not approved"            ask-comment  "$(next_step OPEN other no)"
eq "bot, already approved"          skip-comment "$(next_step OPEN bot yes)"
eq "human, already approved"        'done'       "$(next_step OPEN other yes)"

echo "stop_reason"
eq "open, nothing stops"            ""   "$(stop_reason OPEN bot no)"
eq "bot already approved continues" ""   "$(stop_reason OPEN bot yes)"
eq "merged"  'PR is merged, not open.'   "$(stop_reason MERGED other no)"

echo "ci_state"
eq "no checks"                      none    "$(ci_state 0 0 0 0)"
eq "a failure"                      failing "$(ci_state 5 1 0 2)"
eq "a cancel counts as failing"     failing "$(ci_state 5 0 1 0)"
eq "still running"                  pending "$(ci_state 5 0 0 2)"
eq "all done"                       green   "$(ci_state 5 0 0 0)"

echo "recommend <threads> <ci> <merge_state> <auto_allowed>"
eq "unresolved threads"             not-now   "$(recommend 1 green CLEAN true)"
eq "failing CI"                     not-now   "$(recommend 0 failing CLEAN true)"
eq "green and clean"                merge-now "$(recommend 0 green CLEAN true)"
eq "no CI and clean"                merge-now "$(recommend 0 none CLEAN true)"
eq "pending (label just added)"     automerge "$(recommend 0 pending UNKNOWN true)"
eq "green but blocked"              automerge "$(recommend 0 green BLOCKED true)"
eq "pending, automerge disallowed"  not-now   "$(recommend 0 pending BLOCKED false)"

echo "merge_options <recommended> <auto_allowed>"
eq "automerge first"     automerge,merge-now,not-now "$(merge_options automerge true)"
eq "merge-now first"     merge-now,automerge,not-now "$(merge_options merge-now true)"
eq "not-now first"       not-now,merge-now,automerge "$(merge_options not-now true)"
eq "automerge disallowed" not-now,merge-now          "$(merge_options not-now false)"

echo "summary"
eq "green, no threads" \
    "$(printf 'CI: green (3 pass, 0 fail, 0 pending, 2 skipping)\nNo unresolved review threads.')" \
    "$(summary green 3 0 0 2 '' 0 '' no)"
eq "failing, label added, threads" \
    "$(printf 'CI: failing (3 pass, 1 fail, 0 pending, 0 skipping)\nFailing: knip\ngetsentry checks were just queued by the label.\nUnresolved review threads: 1\n- a.ts:1 @x: fix') " \
    "$(summary failing 3 1 0 0 knip 1 '- a.ts:1 @x: fix' yes) "

echo ""
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
