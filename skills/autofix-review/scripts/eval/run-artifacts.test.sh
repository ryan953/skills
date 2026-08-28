#!/usr/bin/env bash
# Does run.sh clear a previous run's artifacts before it re-reviews a case?
#
# It did not. gather.sh only `mkdir -p`s cards/, links/, refutations/ and
# probes/, and nothing removed what was already in them, so a second run over
# the same work root read the FIRST run's cards back and verdict-rule.sh scored
# them as if they were new. Change the taxonomy, rerun, and you measure the old
# skill while believing you measured the new one -- silently, because a full set
# of artifacts is exactly what a successful run looks like.
#
# --print-briefs is used so the test needs no `claude` binary: it exercises
# prepare_case, which is where the clearing happens.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN="$HERE/run.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/autofix-review-runart.XXXXXX")"
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0
eq() {
    if [ "$3" = "$2" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '  FAIL %s\n       expected: [%s]\n       actual:   [%s]\n' "$1" "$2" "$3"; fi
}

REPO="$T/repo"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@e.com; git -C "$REPO" config user.name T
printf 'function read(o) { return o.id; }\n' > "$REPO/app.js"
git -C "$REPO" add -A; git -C "$REPO" commit -qm 'init'
printf 'function read(o) { return o ? o.id : null; }\n' > "$REPO/app.js"
git -C "$REPO" add -A; git -C "$REPO" commit -qm 'fix: guard null'
SHA="$(git -C "$REPO" rev-parse HEAD)"

# The body carries an issue reference on purpose. Without one the case is
# anchorless, the precheck settles it as N1 before any review is dispatched, and
# no brief is written at all -- so the brief assertions below would pass
# vacuously against a case that was never reviewed.
CASES="$T/labelled.jsonl"
jq -nc --arg sha "$SHA" '{pr:1, label:"ACCEPT_TRUTH", state:"MERGED", arm:"seer",
    head_sha_at_review:$sha, base_ref:"main",
    body:"Fixes SENTRY-1A2B.\n\n## Bug\nNull read on o.id, stack trace attached."}' > "$CASES"

WORK_ROOT="$T/wr"
mkdir -p "$WORK_ROOT/pr-1/cards" "$WORK_ROOT/pr-1/links" "$WORK_ROOT/pr-1/refutations"
printf '{"stale":true}' > "$WORK_ROOT/pr-1/cards/intent.json"
printf '{"stale":true}' > "$WORK_ROOT/pr-1/links/L1.json"
printf '{"stale":true}' > "$WORK_ROOT/pr-1/refutations/L1.json"
printf '{"stale":true}' > "$WORK_ROOT/pr-1/facts.json"

"$RUN" --cases "$CASES" --repo-path "$REPO" --work-root "$WORK_ROOT" \
       --print-briefs --out "$T/preds.jsonl" >/dev/null 2>&1

eq "a stale card is cleared"       "" "$(cat "$WORK_ROOT/pr-1/cards/intent.json" 2>/dev/null)"
eq "a stale link is cleared"       "" "$(cat "$WORK_ROOT/pr-1/links/L1.json" 2>/dev/null)"
eq "a stale refutation is cleared" "" "$(cat "$WORK_ROOT/pr-1/refutations/L1.json" 2>/dev/null)"
eq "stale facts.json is cleared"   "" "$(cat "$WORK_ROOT/pr-1/facts.json" 2>/dev/null)"
# Clearing must not take the gathered inputs with it; the review needs those.
eq "gathered inputs survive"       "yes" \
   "$([ -s "$WORK_ROOT/pr-1/meta.json" ] && echo yes || echo no)"

# --keep-artifacts exists for resuming a run that died part way through.
printf '{"stale":true}' > "$WORK_ROOT/pr-1/cards/intent.json"
"$RUN" --cases "$CASES" --repo-path "$REPO" --work-root "$WORK_ROOT" \
       --print-briefs --keep-artifacts --out "$T/preds2.jsonl" >/dev/null 2>&1
eq "--keep-artifacts keeps them" '{"stale":true}' \
   "$(cat "$WORK_ROOT/pr-1/cards/intent.json" 2>/dev/null)"

# Probes are off unless asked for, so the brief must say so.
grep -q 'SKIP Wave 3' "$T/preds.jsonl" 2>/dev/null \
  && eq "probes are off by default" "yes" "yes" \
  || eq "probes are off by default" "yes" "no (brief did not skip Wave 3)"
"$RUN" --cases "$CASES" --repo-path "$REPO" --work-root "$WORK_ROOT" \
       --print-briefs --probes --out "$T/preds3.jsonl" >/dev/null 2>&1
grep -q 'Wave 3 (probes)' "$T/preds3.jsonl" 2>/dev/null \
  && eq "--probes turns them on" "yes" "yes" \
  || eq "--probes turns them on" "yes" "no (brief did not ask for Wave 3)"

printf 'run-artifacts: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
