#!/usr/bin/env bash
# Tests for the pure decision functions in lib.sh. No network.
#
# Run:  skills/getsentry-tests/scripts/lib.test.sh
# Exit: 0 all pass, 1 any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

PASS=0
FAIL=0

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

S=getsentry/sentry

echo "parse_target"
eq "URL"            "getsentry sentry 9" "$(parse_target https://github.com/getsentry/sentry/pull/9/files)"
eq "bare number"    "getsentry sentry 9" "$(parse_target 9)"
eq "#number"        "getsentry sentry 9" "$(parse_target '#9')"
eq "other repo"     "getsentry relay 9"  "$(parse_target 'getsentry/relay#9')"
eq "branch"         ""                   "$(parse_target feat/x)"

echo "next_step <repo> <state> <has_label> <is_fork> <rerun>"
eq "same-repo PR, no label"  apply "$(next_step $S OPEN no false no)"
eq "fork asks first"         ask   "$(next_step $S OPEN no true no)"
eq "already labelled"        stop  "$(next_step $S OPEN yes false no)"
eq "rerun relabels"          apply "$(next_step $S OPEN yes false yes)"
eq "rerun on a fork asks"    ask   "$(next_step $S OPEN yes true yes)"
eq "not sentry"              stop  "$(next_step getsentry/relay OPEN no false no)"
eq "merged"                  stop  "$(next_step $S MERGED no false no)"

echo "stop_reason"
eq "not sentry" \
    "getsentry/relay has no getsentry dispatch workflow; the label only works on getsentry/sentry." \
    "$(stop_reason getsentry/relay OPEN no no)"
eq "closed"     "PR is closed, not open." "$(stop_reason $S CLOSED no no)"
eq "labelled" \
    'Already labelled "Trigger: getsentry tests" at this head. Run /getsentry-tests <pr> --rerun to send it again.' \
    "$(stop_reason $S OPEN yes no)"
eq "nothing"    "" "$(stop_reason $S OPEN no no)"

echo ""
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
