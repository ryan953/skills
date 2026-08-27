#!/usr/bin/env bash
# End-to-end fixtures — six known-answer cases through the whole mechanical path.
#
# The waves in between need a model, so these supply the cards, links, probes and
# refutations a *correct* set of subagents would have produced, and assert that
# gather.sh reads the repo right and verdict-rule.sh turns those artifacts into
# the right verdict. That covers the wiring the unit tests do not: the join in
# facts_from_work that turns a broken link plus its refutation plus its probe
# into a single reason.
#
# The repos are also the material for a real model-in-the-loop smoke test — run
# the skill against one by hand and see whether the subagents produce artifacts
# resembling the ones written here.
#
# Run:  skills/autofix-review/scripts/eval/fixtures.test.sh
# Exit: 0 all pass, 1 any failure.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL="$(cd "$HERE/../.." && pwd)"
GATHER="$SKILL/scripts/gather.sh"
VERDICT_SH="$SKILL/scripts/verdict-rule.sh"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/autofix-review-fixtures.XXXXXX")"
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

# repo <name> <base-content> <head-content> <commit-msg> — a two-commit repo.
repo() {
    local d="$TMPROOT/$1"
    mkdir -p "$d/src"
    git -C "$d" init -q -b main 2>/dev/null || { git init -q -b main "$d"; }
    git -C "$d" config user.email t@example.com
    git -C "$d" config user.name T
    printf '%s' "$2" > "$d/src/app.ts"
    git -C "$d" add -A && git -C "$d" commit -qm 'init'
    git -C "$d" checkout -qb fix/x
    printf '%s' "$3" > "$d/src/app.ts"
    git -C "$d" add -A && git -C "$d" commit -qm "$4"
    printf '%s\n' "$d"
}

# card <work> <name> <json>
card() { mkdir -p "$1/cards"; printf '%s\n' "$3" > "$1/cards/$2.json"; }
link() { mkdir -p "$1/links"; printf '%s\n' "$3" > "$1/links/$2.json"; }
art()  { mkdir -p "$1/$2";    printf '%s\n' "$4" > "$1/$2/$3.json"; }

# The four links every clean case has.
holds_all() {
    local w="$1"
    for l in L1 L2 L3 L4a L4b; do
        link "$w" "$l" "{\"link\":\"$l\",\"status\":\"holds\",\"citations\":[]}"
    done
    link "$w" P '{"verdict":"matches","priors":[]}'
    link "$w" S '{"verdict":"followed","applicable":[]}'
}

EV_TWO='{"mode":"bugfix","symptom":"TypeError: cannot read id of undefined",
 "failing_frames":[{"file":"src/app.ts","line":2,"in_repo":true},{"file":"src/app.ts","line":6,"in_repo":true}],
 "preconditions":["org is null"],"affected_sites":["src/app.ts:2","src/app.ts:6"],"unavailable":[]}'
RCA_OK='{"present":true,"source":"seer","mechanism":"org can be null before hydration and both readers dereference it",
 "faulty_locations":[{"file":"src/app.ts","line":2},{"file":"src/app.ts","line":6}],"confidence":"high"}'

BASE='export function a(org) { return org.id; }
export function b(org) { return org.id; }
'
GUARD_BOTH='export function a(org) { return org ? org.id : null; }
export function b(org) { return org ? org.id : null; }
'
GUARD_ONE='export function a(org) { return org ? org.id : null; }
export function b(org) { return org.id; }
'

echo "1. a clean fix — both sites the trace names"
R="$(repo clean "$BASE" "$GUARD_BOTH" 'fix(org): guard null org in a and b

Fixes https://sentry.sentry.io/issues/1/')"
W="$TMPROOT/w-clean"
eval "$("$GATHER" --repo-path "$R" --work "$W")"
eq "  mode"          bugfix "$MODE"
eq "  issue found"   1      "$REF_COUNT"
card "$W" evidence "$EV_TWO"
card "$W" rca      "$RCA_OK"
card "$W" intent   '{"claims":[{"id":"c1","text":"guards both readers","kind":"does"}],"divergence_rationale":null}'
card "$W" change   '{"effects":[{"file":"src/app.ts","line":1,"after":"guards"},{"file":"src/app.ts","line":2,"after":"guards"}],"behavioral":true,"suppression_flags":[]}'
holds_all "$W"
art "$W" probes p1 '{"id":"p1","link":"L4a","outcome":"proven","base_result":"fail","head_result":"pass"}'
eval "$("$VERDICT_SH" --work "$W")"
eq "  VERDICT" accept "$VERDICT"
eq "  CODES"   ""     "$CODES"
eq "  SCORED"  full   "$SCORED"

echo ""
echo "2. one of two call sites — R4"
R="$(repo partial "$BASE" "$GUARD_ONE" 'fix(org): guard null org

Fixes https://sentry.sentry.io/issues/1/')"
W="$TMPROOT/w-partial"
eval "$("$GATHER" --repo-path "$R" --work "$W")" >/dev/null
card "$W" evidence "$EV_TWO"
card "$W" rca      "$RCA_OK"
card "$W" intent   '{"claims":[{"id":"c1","text":"guards the null org","kind":"does"}],"divergence_rationale":null}'
card "$W" change   '{"effects":[{"file":"src/app.ts","line":1,"after":"guards"}],"behavioral":true,"suppression_flags":[]}'
holds_all "$W"
link "$W" L4b '{"link":"L4b","status":"broken","code":"R4","citations":["src/app.ts:2","evidence.failing_frames[1]"],"reason":"b() still dereferences org"}'
art "$W" refutations r_R4 '{"reason_id":"L4b","code":"R4","outcome":"survived","citations":["src/app.ts:2"],"argument":"b is exported and called from the same route"}'
art "$W" probes p1 '{"id":"p1","link":"L4b","outcome":"proven-reject","base_result":"fail","head_result":"fail"}'
eval "$("$VERDICT_SH" --work "$W")"
eq "  VERDICT" reject "$VERDICT"
eq "  CODES"   R4     "$CODES"

echo ""
echo "3. swallowing the error — R6"
SWALLOW='export function a(org) { try { return org.id; } catch (e) { return null; } }
export function b(org) { try { return org.id; } catch (e) { return null; } }
'
R="$(repo swallow "$BASE" "$SWALLOW" 'fix(org): stop the crash

Fixes https://sentry.sentry.io/issues/1/')"
W="$TMPROOT/w-swallow"
eval "$("$GATHER" --repo-path "$R" --work "$W")" >/dev/null
card "$W" evidence "$EV_TWO"
card "$W" rca      "$RCA_OK"
card "$W" intent   '{"claims":[{"id":"c1","text":"stops the crash","kind":"does"}],"divergence_rationale":null}'
card "$W" change   '{"effects":[{"file":"src/app.ts","line":1,"after":"returns null on throw"}],"behavioral":true,
 "suppression_flags":[{"kind":"try-catch","file":"src/app.ts","line":1,"swallows":"the null org is still null, callers now silently get null"}]}'
holds_all "$W"
link "$W" L1 '{"link":"L1","status":"broken","code":"R6","citations":["src/app.ts:1","rca.mechanism"],"reason":"the null org persists; only the throw is hidden"}'
art "$W" refutations r_R6 '{"reason_id":"L1","code":"R6","outcome":"survived","citations":["src/app.ts:1"],"argument":"no assignment or guard makes org non-null"}'
art "$W" probes p1 '{"id":"p1","link":"L4a","outcome":"proven","base_result":"fail","head_result":"pass"}'
eval "$("$VERDICT_SH" --work "$W")"
# The probe passes — the crash really did stop — and the change is still rejected,
# because R6 is about the state the RCA named, not about whether the throw is gone.
eq "  VERDICT" reject "$VERDICT"
eq "  CODES"   R6     "$CODES"

echo ""
echo "4. silencing the rule — R7 (lintfix)"
R="$(repo disable 'console.log(1);
' '// eslint-disable-next-line no-console
console.log(1);
' 'ref(lint): quiet no-console')"
W="$TMPROOT/w-disable"
eval "$("$GATHER" --repo-path "$R" --work "$W")"
eq "  mode"           lintfix "$MODE"
eq "  no issue is ok" ""      "$UNAVAILABLE"
card "$W" evidence '{"mode":"lintfix","source":"eslint:no-console","symptom":"no-console fires","affected_sites":["src/app.ts:1"],"unavailable":[]}'
card "$W" rca      '{"present":true,"source":"derived-from-rule","mechanism":"console.log ships to production","confidence":"high"}'
card "$W" intent   '{"claims":[{"id":"c1","text":"quiets the rule","kind":"does"}],"divergence_rationale":null}'
card "$W" change   '{"effects":[],"behavioral":false,"suppression_flags":[{"kind":"eslint-disable","file":"src/app.ts","line":1,"swallows":"the rule, not the console call"}]}'
holds_all "$W"
link "$W" L2 '{"link":"L2","status":"broken","code":"R7","citations":["src/app.ts:1"],"reason":"disables the rule rather than removing the call"}'
art "$W" refutations r_R7 '{"reason_id":"L2","code":"R7","outcome":"survived","citations":["src/app.ts:2"],"argument":"the console call is unchanged"}'
eval "$("$VERDICT_SH" --work "$W")"
eq "  VERDICT" reject "$VERDICT"
eq "  CODES"   R7     "$CODES"

echo ""
echo "4b. the same suppression, explained — N4 not R7"
W="$TMPROOT/w-disable-explained"
cp -r "$TMPROOT/w-disable" "$W"
card "$W" intent '{"claims":[{"id":"c1","text":"quiets the rule","kind":"does"}],
 "divergence_rationale":"this file is the CLI entrypoint; console IS the output here"}'
eval "$("$VERDICT_SH" --work "$W")"
# A stated reason turns a convertible code into a person'"'"'s call. Without this,
# every considered tradeoff reads as a defect and the reject rate fills with
# false positives.
eq "  VERDICT" needs-human "$VERDICT"
eq "  CODES"   N4          "$CODES"

echo ""
echo "5. scope creep — R3"
CREEP='export function a(org) { return org ? org.id : null; }
export function b(org) { return org ? org.id : null; }
export const fmt = (s) => s.trim().toUpperCase();
'
R="$(repo creep "$BASE" "$CREEP" 'fix(org): guard null org

Fixes https://sentry.sentry.io/issues/1/')"
W="$TMPROOT/w-creep"
eval "$("$GATHER" --repo-path "$R" --work "$W")" >/dev/null
card "$W" evidence "$EV_TWO"
card "$W" rca      "$RCA_OK"
card "$W" intent   '{"claims":[{"id":"c1","text":"guards the null org","kind":"does"}],"divergence_rationale":null}'
card "$W" change   '{"effects":[{"file":"src/app.ts","line":1,"after":"guards"},{"file":"src/app.ts","line":3,"after":"adds an exported fmt helper"}],
 "behavioral":true,"side_effects":["adds a new export the description never mentions"],"suppression_flags":[]}'
holds_all "$W"
link "$W" L3 '{"link":"L3","status":"broken","code":"R3","citations":["src/app.ts:3"],"reason":"adds an exported helper the description never claims"}'
art "$W" refutations r_R3 '{"reason_id":"L3","code":"R3","outcome":"survived","citations":["src/app.ts:3"],"argument":"nothing in the body or commit mentions fmt"}'
art "$W" probes p1 '{"id":"p1","link":"L4a","outcome":"proven","base_result":"fail","head_result":"pass"}'
eval "$("$VERDICT_SH" --work "$W")"
eq "  VERDICT" reject "$VERDICT"
eq "  CODES"   R3     "$CODES"

echo ""
echo "6. no issue anywhere — N1"
R="$(repo anchorless "$BASE" "$GUARD_BOTH" 'fix: tidy up')"
W="$TMPROOT/w-anchorless"
eval "$("$GATHER" --repo-path "$R" --work "$W")"
eq "  gather flags it" issue "$UNAVAILABLE"
card "$W" evidence '{"mode":"bugfix","symptom":"unknown","affected_sites":[],"unavailable":["issue"]}'
card "$W" rca      '{"present":false}'
card "$W" intent   '{"claims":[],"divergence_rationale":null}'
card "$W" change   '{"effects":[{"file":"src/app.ts","line":1,"after":"guards"}],"behavioral":true,"suppression_flags":[]}'
holds_all "$W"
eval "$("$VERDICT_SH" --work "$W")"
eq "  VERDICT" needs-human "$VERDICT"
eq "  CODES"   N1          "$CODES"

echo ""
echo "5b. a refutation for another link does not save this one"
W="$TMPROOT/w-creep-wronglink"
cp -r "$TMPROOT/w-creep" "$W"
art "$W" refutations r_R3 '{"reason_id":"L4a","code":"R3","outcome":"survived","citations":["src/app.ts:3"],"argument":"examined a different link entirely"}'
eval "$("$VERDICT_SH" --work "$W")"
# Same code, wrong link: the finding loses its refutation and cannot stand.
eq "  VERDICT" needs-human "$VERDICT"

echo ""
echo "7. read-only scoring of the clean case"
W="$TMPROOT/w-readonly"
cp -r "$TMPROOT/w-clean" "$W"
rm -f "$W"/probes/*.json
eval "$("$VERDICT_SH" --work "$W" --read-only)"
eq "  VERDICT" accept    "$VERDICT"
eq "  SCORED"  read-only "$SCORED"
# The same artifacts scored normally cannot reach accept: no probe ran, so the
# closing link was read and not measured.
eval "$("$VERDICT_SH" --work "$W")"
eq "  full scoring defers instead" needs-human "$VERDICT"
eq "  and says why"                N3          "$CODES"

echo ""
printf 'fixtures: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
