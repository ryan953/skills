#!/usr/bin/env bash
# test.sh — every test in this skill. No network, no gh, no toolchain.
#
# Run this before touching the taxonomy, the verdict rule, or the probe gate.
# Those three are the precision surface, and a change that loosens one of them
# is exactly the kind that looks harmless in a diff.
#
# The files run concurrently. Serially the suite takes ~48s, and almost all of
# it is two files -- gather and fixtures -- that spend their time in git and
# subprocesses rather than on CPU; the rest finish in under three seconds each.
# Each test builds its own `mktemp -d` and shares nothing, so the only thing
# serial execution bought was a suite slow enough to be run less often. Output
# is still collected and printed in file order, so a run is as readable and as
# reproducible as it was before. JOBS=1 restores serial execution when a
# failure is easier to read that way.
#
# Written for macOS's bash 3.2: no `wait -n`, no associative arrays.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)}"
[ "$JOBS" -ge 1 ] 2>/dev/null || JOBS=4
[ "$JOBS" -le 8 ] || JOBS=8

TESTS=()
for t in "$HERE"/*.test.sh "$HERE"/eval/*.test.sh; do
    [ -f "$t" ] && TESTS[${#TESTS[@]}]="$t"
done
[ "${#TESTS[@]}" -gt 0 ] || { printf 'no tests found under %s\n' "$HERE"; exit 1; }

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/autofix-review-test.XXXXXX")" || exit 1
trap 'rm -rf "$TMPD"' EXIT

# shellcheck is started first and in the background: it is the one check that
# reads every file at once, so it overlaps with the tests instead of following
# them. It found the bug that mattered most here: a `local a=$1 b=$a`, where
# every word is expanded before any assignment lands, so `b` silently read an
# unset variable. Three of those shipped in this skill before the linter was
# ever run on it.
#
# Note the wording of this comment. A line beginning "# shellcheck" is parsed as
# a DIRECTIVE, and a prose one fails to parse and reports as a finding -- which
# is how this block failed the first time it ran. LC_ALL is set because the
# comments in these scripts are UTF-8 and shellcheck errors on non-ASCII output
# under a C locale.
if command -v shellcheck >/dev/null 2>&1; then
    ( LC_ALL=C.UTF-8 shellcheck -S warning -e SC1090 -x "$HERE"/*.sh "$HERE"/eval/*.sh \
        > "$TMPD/sc.out" 2>&1; printf '%s' "$?" > "$TMPD/sc.rc" ) &
else
    printf 'skipped' > "$TMPD/sc.skip"
fi

i=0
for t in "${TESTS[@]}"; do
    while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$JOBS" ]; do sleep 0.2; done
    ( out="$("$t" 2>&1)"; rc=$?
      printf '%s\n' "$out" > "$TMPD/$i.out"; printf '%s' "$rc" > "$TMPD/$i.rc" ) &
    i=$((i + 1))
done
wait

FAILED=0
i=0
for t in "${TESTS[@]}"; do
    out="$(cat "$TMPD/$i.out" 2>/dev/null)"
    rc="$(cat "$TMPD/$i.rc" 2>/dev/null || echo 1)"
    printf '%-24s %s\n' "$(basename "$t" .test.sh)" "$(printf '%s' "$out" | tail -1)"
    if [ "$rc" != 0 ]; then
        FAILED=1
        printf '%s\n' "$out" | grep -B1 -A3 '  FAIL' | sed 's/^/    /'
        # A test that dies before printing a "  FAIL" line -- a syntax error, a
        # missing fixture -- would otherwise report as a blank line and a green
        # summary, so show its tail unconditionally when nothing matched.
        printf '%s\n' "$out" | grep -q '  FAIL' || printf '%s\n' "$out" | tail -5 | sed 's/^/    /'
    fi
    i=$((i + 1))
done

if [ -f "$TMPD/sc.skip" ]; then
    printf '%-24s %s\n' shellcheck "not installed (skipped)"
elif [ -s "$TMPD/sc.out" ]; then
    FAILED=1
    printf '%-24s %s\n' shellcheck "findings:"
    sed 's/^/    /' "$TMPD/sc.out"
else
    printf '%-24s %s\n' shellcheck "clean"
fi

[ "$FAILED" -eq 0 ] && printf '\nall green\n' || printf '\nFAILURES above\n'
exit "$FAILED"
