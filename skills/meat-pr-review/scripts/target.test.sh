#!/usr/bin/env bash
# Tests for target.sh — the pure target-classification helpers. No network, no
# repo, no meat binary, so every routing branch is cheap to assert.
#
# Run:  skills/meat-pr-review/scripts/target.test.sh
# Exit: 0 all pass, 1 any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=target.sh
. "$SCRIPT_DIR/target.sh"

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

echo "classify_target"
eq "no target -> auto"            auto    "$(classify_target)"
eq "empty string -> auto"         auto    "$(classify_target '')"
eq "bare number -> pr"            pr      "$(classify_target 121125)"
eq "#number -> pr"                pr      "$(classify_target '#42')"
eq "#notanumber -> unknown"       unknown "$(classify_target '#42x')"
eq "pull URL -> pr"               pr      "$(classify_target https://github.com/getsentry/sentry/pull/121125)"
eq "pull URL with /files -> pr"   pr      "$(classify_target https://github.com/o/n/pull/7/files)"
eq "issue URL -> unknown"         unknown "$(classify_target https://github.com/o/n/issues/7)"
eq "two-dot range"                range   "$(classify_target main..HEAD)"
eq "three-dot range"              range   "$(classify_target origin/main...feat/x)"
eq "open-ended range"             range   "$(classify_target 'main..')"
eq "branch name -> ref"           ref     "$(classify_target feat/thing)"
eq "sha -> ref"                   ref     "$(classify_target 9fceb02)"
# A branch with a dot in the name is still a ref: only a doubled dot is a range.
eq "branch with a dot -> ref"     ref     "$(classify_target release/1.2)"

echo ""
echo "pr_number"
eq "bare number"        121125 "$(pr_number 121125)"
eq "hash prefix"        42     "$(pr_number '#42')"
eq "from URL"           121125 "$(pr_number https://github.com/getsentry/sentry/pull/121125)"
eq "from URL + /files"  7      "$(pr_number https://github.com/o/n/pull/7/files)"
eq "from URL + anchor"  7      "$(pr_number 'https://github.com/o/n/pull/7#discussion_r1')"
eq "from URL + query"   7      "$(pr_number 'https://github.com/o/n/pull/7?w=1')"
eq "branch name fails"  ''     "$(pr_number feat/x)"

echo ""
echo "split_range"
eq "two-dot"                     "$(printf 'main\tHEAD\t..')"          "$(split_range main..HEAD)"
eq "three-dot preserved"         "$(printf 'origin/main\tfeat/x\t...')" "$(split_range origin/main...feat/x)"
# git's own defaulting: an omitted side means HEAD on that side.
eq "omitted head -> HEAD"        "$(printf 'main\tHEAD\t..')"          "$(split_range 'main..')"
eq "omitted base -> HEAD"        "$(printf 'HEAD\tmain\t..')"          "$(split_range '..main')"
eq "not a range fails"           ''                                     "$(split_range main)"

echo ""
echo "resolve_mode"
eq "pr class -> pr"                  pr    "$(resolve_mode pr no auto)"
eq "range class -> local"            local "$(resolve_mode range no auto)"
eq "ref with a PR -> pr"             pr    "$(resolve_mode ref yes auto)"
eq "ref without a PR -> local"       local "$(resolve_mode ref no auto)"
eq "auto with a PR -> pr"            pr    "$(resolve_mode auto yes auto)"
eq "auto without a PR -> local"      local "$(resolve_mode auto no auto)"
eq "unknown stays unknown"           unknown "$(resolve_mode unknown no auto)"
# --local must win even where a PR exists, or "review what's on disk" would
# silently become "review what's pushed".
eq "--local beats an existing PR"    local "$(resolve_mode ref yes local)"
eq "--pr beats no PR found"          pr    "$(resolve_mode ref no pr)"
eq "--pr beats a range-looking arg"  pr    "$(resolve_mode range no pr)"

echo ""
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
