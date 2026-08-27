#!/usr/bin/env bash
# test.sh — every test in this skill. No network, no gh, no toolchain.
#
# Run this before touching the taxonomy, the verdict rule, or the probe gate.
# Those three are the precision surface, and a change that loosens one of them
# is exactly the kind that looks harmless in a diff.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

FAILED=0
for t in "$HERE"/*.test.sh "$HERE"/eval/*.test.sh; do
    [ -f "$t" ] || continue
    out="$("$t" 2>&1)"; rc=$?
    printf '%-24s %s\n' "$(basename "$t" .test.sh)" "$(printf '%s' "$out" | tail -1)"
    if [ "$rc" -ne 0 ]; then
        FAILED=1
        printf '%s\n' "$out" | grep -B1 -A3 '  FAIL' | sed 's/^/    /'
    fi
done
# shellcheck, when it is installed. It found the bug that mattered most here —
# a `local a=$1 b=$a` where every word is expanded before any assignment lands,
# so `b` silently read an unset variable. Three of those shipped in this skill
# before the linter was run on it.
if command -v shellcheck >/dev/null 2>&1; then
    sc_out="$(shellcheck -S warning -e SC1090 -x "$HERE"/*.sh "$HERE"/eval/*.sh 2>&1)"
    if [ -n "$sc_out" ]; then
        FAILED=1
        printf '%-24s %s\n' shellcheck "findings:"
        printf '%s\n' "$sc_out" | sed 's/^/    /'
    else
        printf '%-24s %s\n' shellcheck "clean"
    fi
else
    printf '%-24s %s\n' shellcheck "not installed (skipped)"
fi

[ "$FAILED" -eq 0 ] && printf '\nall green\n' || printf '\nFAILURES above\n'
exit "$FAILED"
