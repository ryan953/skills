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

cd "$T"
number=900; head_at_review="$OWN"
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
