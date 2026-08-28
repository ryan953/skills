#!/usr/bin/env bash
# Does slice.sh's supersession range exclude the PR's OWN squash commit?
#
# It did not. `head_sha_at_review..HEAD` still contains the squash commit that
# merged the PR, and that commit names the same issue -- so superseded_later
# matched every merged case against itself and labelled the entire merged arm
# REJECT_TRUTH. A yardstick that calls every accept a reject is worse than none:
# it would have made the skill look precise while measuring nothing.
#
# Both directions matter, so both are asserted: the PR must not match itself,
# and a genuine follow-up must still be found.
set -uo pipefail
# Resolved before the cd below: everything after it runs inside a fixture repo.
SLICE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/slice.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
git init -q -b main "$T"; git -C "$T" config user.email t@e.com; git -C "$T" config user.name T
echo a > "$T/a"; git -C "$T" add -A; git -C "$T" commit -qm 'seed'
# the PR's own squash commit, naming its issue
echo b > "$T/a"; git -C "$T" add -A
git -C "$T" commit -qm 'fix(x): guard tags (#900)

Fixes SENTRY-5F52.'
OWN=$(git -C "$T" rev-parse HEAD)
# unrelated later work
echo c > "$T/b"; git -C "$T" add -A; git -C "$T" commit -qm 'feat: unrelated (#901)'

cd "$T" || exit 1
number=900
own="$(git log --format='%H %s' -n 4000 2>/dev/null | grep -m1 -F "(#$number)" | cut -d" " -f1 || true)"
later="$(git log --format='%s%n%b' "$own..HEAD" 2>/dev/null || true)"
if printf '%s' "$later" | grep -qF 'SENTRY-5F52'; then
  echo "FAIL: the PR still matches its own issue -> every merged case becomes REJECT_TRUTH"; exit 1
fi
echo "ok: own squash commit excluded from the supersession range"
# and a genuine follow-up IS still seen
echo d > "$T/a"; git -C "$T" add -A; git -C "$T" commit -qm 'fix(x): really guard tags (#950)

Fixes: SENTRY-5F52.'
later="$(git log --format='%s%n%b' "$own..HEAD" 2>/dev/null || true)"
printf '%s' "$later" | grep -qF 'SENTRY-5F52' \
  && echo "ok: a real follow-up is still detected" \
  || { echo "FAIL: a real follow-up was missed"; exit 1; }

# The fallback branch: when the PR's own commit cannot be found by its marker,
# slice.sh falls back to head_at_review..HEAD and drops whole commits naming
# this PR. That must not let the PR match itself.
#
# The function is EXTRACTED from slice.sh, not restated. A copy of it here is
# what let a fatal bug ship: the real pipeline ended in `head -c` with no
# `|| true`, so under `set -e` and `set -o pipefail` a SIGPIPE from head killed
# slice.sh silently, and every run over CLOSED PRs produced an empty sample --
# while this test, with no `set -e` and a three-commit repo, stayed green.
block="$(sed -n '/^#>>> supersession-fallback$/,/^#<<< supersession-fallback$/p' "$SLICE")"
[ -n "$block" ] || { echo "FAIL: supersession-fallback markers missing from slice.sh"; exit 1; }
eval "$block"

head_at_review="$OWN"
fb="$(supersession_fallback "$head_at_review..HEAD" "$number")"
# Check the marker, not the words: "really guard tags" contains "guard tags".
if printf '%s' "$fb" | grep -qF "(#$number)"; then
  echo "FAIL: the fallback still lets the PR match itself"; exit 1
fi
printf '%s' "$fb" | grep -qF '(#950)' \
  || { echo "FAIL: the fallback lost the follow-up"; exit 1; }
echo "ok: the fallback drops this PR but keeps the follow-up"

# Only the SUBJECT carries the squash marker. A follow-up that cites this PR in
# its body is a genuine supersession and must survive.
echo e > "$T/c"; git -C "$T" add -A
git -C "$T" commit -qm 'fix(x): third attempt (#980)

Supersedes (#900). Fixes SENTRY-5F52.'
fb2="$(supersession_fallback "$head_at_review..HEAD" "$number")"
printf '%s' "$fb2" | grep -qF '(#980)' \
  || { echo "FAIL: a body mention dropped a genuine follow-up"; exit 1; }
echo "ok: a follow-up citing this PR in its body is kept"

# The bug that took a whole run down. `head -c` closes the pipe once it has its
# 200KB; git gets SIGPIPE, pipefail turns that into a failed pipeline, and set -e
# kills the caller. Needs a range whose output exceeds the cap -- a few large
# commit bodies, rather than the thousands of small ones a real repo has.
BIG="$(mktemp -d "${TMPDIR:-/tmp}/autofix-review-sigpipe.XXXXXX")"
trap 'rm -rf "$T" "$BIG"' EXIT
git init -q -b main "$BIG"; git -C "$BIG" config user.email t@e.com; git -C "$BIG" config user.name T
echo seed > "$BIG/f"; git -C "$BIG" add -A; git -C "$BIG" commit -qm seed
BIGBASE="$(git -C "$BIG" rev-parse HEAD)"
FILLER="$(head -c 25000 /dev/zero | tr '\0' x)"
i=0
while [ "$i" -lt 10 ]; do
    printf '%s\n' "$i" > "$BIG/f"; git -C "$BIG" add -A
    git -C "$BIG" commit -qm "commit $i" -m "$FILLER"
    i=$((i + 1))
done

rc=0
( cd "$BIG" && set -euo pipefail && eval "$block" \
  && supersession_fallback "$BIGBASE..HEAD" 900 > /dev/null ) || rc=$?
[ "$rc" -eq 0 ] \
  || { echo "FAIL: the fallback exits $rc under set -e when head -c closes the pipe"; exit 1; }
echo "ok: survives head -c closing the pipe under set -e and pipefail"
