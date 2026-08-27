#!/usr/bin/env bash
# Tests for probe-run.sh — real git worktrees, a fake runner, no node toolchain.
#
# The runner is just `bash`, and the "probe test" is a shell script that inspects
# the tree it finds itself in. That is enough to exercise every outcome of the
# base/head gate without installing a test framework, and the gate is the part
# worth pinning: it is what separates a measurement from a green checkmark.
#
# Run:  skills/autofix-review/scripts/probe-run.test.sh
# Exit: 0 all pass, 1 any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROBE="$SCRIPT_DIR/probe-run.sh"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/autofix-review-probe.XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0
FAIL=0
eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        PASS=$((PASS+1)); printf '  ok   %s\n' "$name"
    else
        FAIL=$((FAIL+1))
        printf '  FAIL %s\n       expected: [%s]\n       actual:   [%s]\n' "$name" "$expected" "$actual"
    fi
}

# A repo whose base has the bug and whose head fixes it.
REPO="$TMPROOT/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name T
printf 'function read(o) { return o.id; }\n' > "$REPO/app.js"
git -C "$REPO" add -A && git -C "$REPO" commit -qm 'init'
BASE="$(git -C "$REPO" rev-parse HEAD)"
printf 'function read(o) { return o ? o.id : null; }\n' > "$REPO/app.js"
git -C "$REPO" add -A && git -C "$REPO" commit -qm 'fix: guard null'
HEAD="$(git -C "$REPO" rev-parse HEAD)"

WORK="$TMPROOT/work"
mkdir -p "$WORK/raw"
printf 'app.js\n' > "$WORK/raw/files.txt"
jq -n --arg b "$BASE" --arg h "$HEAD" --arg r "$REPO" \
    '{base_sha:$b, head_sha:$h, repo_path:$r}' > "$WORK/meta.json"

# probe_for <name> <script body> — a probe file that runs under plain bash.
probe_for() {
    local f="$TMPROOT/$1.probe.test.sh"
    printf '%s\n' "$2" > "$f"
    printf '%s\n' "$f"
}

run() {  # run <probe> <runner> -> "OUTCOME rc"
    local out rc
    out="$("$PROBE" --work "$WORK" --id "$3" --test "$1" --runner "$2" --repo-path "$REPO" 2>&1)"
    rc=$?
    printf '%s %s\n' "$(printf '%s' "$out" | sed -n "s/^OUTCOME='\(.*\)'$/\1/p")" "$rc"
}

echo "the base/head gate"
# Reproduces the bug: the unguarded read exists at base, not at head.
P_REAL="$(probe_for real 'grep -q "return o.id" app.js && exit 1 || exit 0')"
eq "fails at base, passes at head -> proven" "proven 0" "$(run "$P_REAL" 'bash {}' p_real)"

# Still broken at head: asserts something the fix never did.
P_STILL="$(probe_for still 'grep -q "assertNever" app.js && exit 0 || exit 1')"
eq "fails at both -> proven-reject" "proven-reject 1" "$(run "$P_STILL" 'bash {}' p_still)"

# The gate: passes at base, so it never reproduced anything. Discarded, and the
# head run is skipped entirely — there is nothing left to learn from it.
P_VAC="$(probe_for vacuous 'exit 0')"
eq "passes at base -> invalid" "invalid 2" "$(run "$P_VAC" 'bash {}' p_vac)"
eq "invalid skips the head run" "skipped" "$(jq -r .head_result "$WORK/probes/p_vac.json")"
eq "invalid says why"  "true" \
   "$(jq -r '.detail | test("does not reproduce")' "$WORK/probes/p_vac.json")"

# A harness that never ran is not evidence either way.
eq "missing runner -> unprovable" "unprovable 3" "$(run "$P_REAL" 'no-such-runner-xyz {}' p_err)"
eq "unprovable is not recorded as a failure" "error" \
   "$(jq -r .base_result "$WORK/probes/p_err.json")"

echo ""
echo "records and hygiene"
eq "the proven record is written" "proven" "$(jq -r .outcome "$WORK/probes/p_real.json")"
eq "base/head results are both kept" "fail pass" \
   "$(jq -r '"\(.base_result) \(.head_result)"' "$WORK/probes/p_real.json")"
# The probe is placed beside the changed file so relative paths and test globs
# resolve the way a real test in that package would.
eq "dest sits beside the changed file" "real.probe.test.sh" \
   "$(jq -r .dest "$WORK/probes/p_real.json")"
# Nothing survives the run: no probe files left behind, no worktrees still
# registered against the user's clone.
eq "no probe files left in the repo" "" \
   "$(find "$REPO" -name '*.probe.test.*' 2>/dev/null)"
eq "no worktrees left registered" "1" \
   "$(git -C "$REPO" worktree list | wc -l | tr -d ' ')"

echo ""
echo "the probe never clobbers a tracked file"
# The probe is removed after each run, so writing over an existing file would
# delete it from the worktree -- and persist that under --keep-worktrees.
P_CLOB="$(probe_for clobber 'exit 0')"
out="$("$PROBE" --work "$WORK" --id p_clob --test "$P_CLOB" --runner 'bash {}' \
        --repo-path "$REPO" --dest app.js 2>&1)"
eq "refuses to overwrite app.js" "unprovable" \
   "$(printf '%s' "$out" | sed -n "s/^OUTCOME='\(.*\)'$/\1/p")"
eq "and app.js survives" "function read(o) { return o ? o.id : null; }" \
   "$(git -C "$REPO" show HEAD:app.js | tr -d '\n')"

echo ""
echo "runner argument forms"
P_ARG="$(probe_for argform 'grep -q "return o.id" app.js && exit 1 || exit 0')"
eq "{} substitution"  "proven 0" "$(run "$P_ARG" 'bash {}' p_sub)"
eq "appended argument" "proven 0" "$(run "$P_ARG" 'bash' p_app)"

echo ""
printf 'probe-run: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
