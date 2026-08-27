#!/usr/bin/env bash
# Tests that every script can find the other scripts it shells out to.
#
# This exists because run.sh could not. It computed SKILL_DIR as "$HERE/.."
# from scripts/eval, landing on scripts/, so every path it built came out as
# scripts/scripts/... and it had never once produced a prediction. The failure
# is a stderr line per case plus an empty output file, which score.sh then
# reports as "no scored cases" -- identical to a sample that was legitimately
# empty. Nothing in a unit test of a pure function can catch that.
#
# Run:  skills/autofix-review/scripts/eval/paths.test.sh

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PASS=0
FAIL=0
ok() { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '  FAIL %s\n       %s\n' "$1" "$2"; }

# resolved <script> <var-assignment-line-prefix> — evaluate the directory a
# script computes for itself, exactly as the script does.
echo "cross-script paths resolve"

# run.sh reaches back to the skill root for gather.sh and verdict-rule.sh.
RUN_SKILL_DIR="$(cd "$HERE/../.." && pwd)"
for rel in scripts/gather.sh scripts/verdict-rule.sh reference/cards.md; do
    if [ -e "$RUN_SKILL_DIR/$rel" ]; then ok "run.sh -> $rel"
    else no "run.sh -> $rel" "not at $RUN_SKILL_DIR/$rel"; fi
done

# The value run.sh actually computes must match, or this test is checking a
# constant rather than the script.
ACTUAL="$(grep -m1 '^SKILL_DIR=' "$HERE/run.sh")"
case "$ACTUAL" in
    *'$HERE/../..'*) ok "run.sh computes SKILL_DIR two levels up" ;;
    *) no "run.sh computes SKILL_DIR two levels up" "found: $ACTUAL" ;;
esac

# pilot.sh drives its siblings from its own directory.
for rel in collect.sh slice.sh label.sh run.sh score.sh; do
    if [ -x "$HERE/$rel" ]; then ok "pilot.sh -> $rel"
    else no "pilot.sh -> $rel" "missing or not executable"; fi
done

# gather.sh, probe-run.sh and verdict-rule.sh probe for local-pr-review's lib.sh
# and degrade to stubs when it is absent; the in-repo path must at least resolve.
SKILL_ROOT="$(cd "$HERE/../.." && pwd)"
if [ -f "$SKILL_ROOT/scripts/../../local-pr-review/scripts/lib.sh" ]; then
    ok "scripts -> local-pr-review/scripts/lib.sh"
else
    no "scripts -> local-pr-review/scripts/lib.sh" "sibling skill not found from $SKILL_ROOT"
fi

echo ""
printf 'paths: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
