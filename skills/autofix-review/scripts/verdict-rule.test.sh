#!/usr/bin/env bash
# Tests for verdict-rule.sh — every row of the accept / reject / needs-human
# table, plus the filters that drop a finding before it can become a verdict.
# No network, no repo, no model: the decision is pure, so it is cheap to pin.
#
# Run:  skills/autofix-review/scripts/verdict-rule.test.sh
# Exit: 0 all pass, 1 any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=verdict-rule.sh
. "$SCRIPT_DIR/verdict-rule.sh"

PASS=0
FAIL=0

# v <name> <expected "verdict|codes"> <facts json>
v() {
    local name="$1" expected="$2" facts="$3" out actual
    out="$(decide "$facts")"
    actual="$(printf '%s' "$out" | awk -F'\t' '{print $1 "|" $2}')"
    if [ "$actual" = "$expected" ]; then
        PASS=$((PASS+1)); printf '  ok   %s\n' "$name"
    else
        FAIL=$((FAIL+1))
        printf '  FAIL %s\n       expected: [%s]\n       actual:   [%s]\n' "$name" "$expected" "$actual"
    fi
}

# scored <name> <expected> <facts json>
scored() {
    local name="$1" expected="$2" facts="$3" actual
    actual="$(decide "$facts" | awk -F'\t' '{print $3}')"
    if [ "$actual" = "$expected" ]; then
        PASS=$((PASS+1)); printf '  ok   %s\n' "$name"
    else
        FAIL=$((FAIL+1))
        printf '  FAIL %s\n       expected: [%s]\n       actual:   [%s]\n' "$name" "$expected" "$actual"
    fi
}

# ---- building blocks --------------------------------------------------------
ALL_HOLD='[{"link":"L1","status":"holds"},{"link":"L2","status":"holds"},{"link":"L3","status":"holds"},{"link":"L4a","status":"holds"},{"link":"L4b","status":"holds"}]'
PROVEN='[{"id":"p1","outcome":"proven"}]'

# facts <<overrides json>> — a clean accepting case, then merged with overrides.
facts() {
    local o="${1:-}"; [ -n "$o" ] || o='{}'
    jq -cn --argjson links "$ALL_HOLD" --argjson probes "$PROVEN" --argjson o "$o" '
        {mode:"bugfix", behavioral:true, rca_present:true, unavailable:[],
         probes_required:true, divergence_rationale:null,
         standards_verdict:"followed", precedent_verdict:"matches",
         links:$links, reasons:[], probes:$probes} * $o'
}

echo "accept — earned"
v "all links hold + probe proven"   "accept|"      "$(facts)"
v "non-behavioural needs no probe"  "accept|"      "$(facts '{"behavioral":false,"probes":[]}')"
v "read-only relaxes the probe"     "accept|"      "$(facts '{"probes":[],"probes_required":false}')"
scored "read-only is labelled"      read-only      "$(facts '{"probes":[],"probes_required":false}')"
scored "full scoring is labelled"   full           "$(facts)"

echo ""
echo "reject — cited and survived"
v "R4 survived a refuter"  "reject|R4" \
  "$(facts '{"reasons":[{"id":"r1","code":"R4","citations":["a.tsx:12"],"survived":true}]}')"
v "R1 proven by a probe"   "reject|R1" \
  "$(facts '{"reasons":[{"id":"r1","code":"R1","citations":["a.tsx:1"],"survived":false,"probe":"proven-reject"}]}')"
v "two codes, sorted"      "reject|R3,R6" \
  "$(facts '{"reasons":[{"id":"r2","code":"R6","citations":["b:2"],"survived":true},{"id":"r1","code":"R3","citations":["a:1"],"survived":true}]}')"
v "duplicate codes collapse" "reject|R4" \
  "$(facts '{"reasons":[{"id":"r1","code":"R4","citations":["a:1"],"survived":true},{"id":"r2","code":"R4","citations":["b:2"],"survived":true}]}')"

echo ""
echo "reject — the filters that drop a finding"
# Each of these would be a reject but for one missing requirement. Dropping
# rather than softening is the whole precision argument.
v "uncited finding is dropped"      "needs-human|N2" \
  "$(facts '{"reasons":[{"id":"r1","code":"R4","citations":[],"survived":true}],"links":[{"link":"L1","status":"broken","code":"R4","citations":[]},{"link":"L2","status":"holds"},{"link":"L3","status":"holds"},{"link":"L4a","status":"holds"},{"link":"L4b","status":"holds"}]}')"
v "refuted finding is dropped"      "needs-human|N2" \
  "$(facts '{"reasons":[{"id":"r1","code":"R4","citations":["a:1"],"survived":false}]}')"
v "unknown code is dropped"         "accept|" \
  "$(facts '{"reasons":[{"id":"r1","code":"R9","citations":["a:1"],"survived":true}]}')"
v "empty code is dropped"           "accept|" \
  "$(facts '{"reasons":[{"id":"r1","code":"","citations":["a:1"],"survived":true}]}')"

echo ""
echo "N1 — the chain has no anchor (checked before everything)"
v "no RCA in bugfix mode"        "needs-human|N1" "$(facts '{"rca_present":false}')"
v "no RCA is fine for lintfix"   "accept|"        "$(facts '{"rca_present":false,"mode":"lintfix"}')"
v "issue unreadable"             "needs-human|N1" "$(facts '{"unavailable":["issue"]}')"
v "diff unresolvable"            "needs-human|N1" "$(facts '{"unavailable":["diff"]}')"
v "an unrelated gap is not N1"   "accept|"        "$(facts '{"unavailable":["breadcrumbs"]}')"
v "no links at all"              "needs-human|N1" "$(facts '{"links":[]}')"
# N1 outranks a would-be reject: a finding derived from an input we never read
# is a guess with a code attached.
v "N1 beats a surviving reject"  "needs-human|N1" \
  "$(facts '{"rca_present":false,"reasons":[{"id":"r1","code":"R4","citations":["a:1"],"survived":true}]}')"

echo ""
echo "N2 — two competent passes disagree"
v "L4 framings disagree (a holds, b broken)" "needs-human|N2" \
  "$(facts '{"links":[{"link":"L1","status":"holds"},{"link":"L2","status":"holds"},{"link":"L3","status":"holds"},{"link":"L4a","status":"holds"},{"link":"L4b","status":"broken","code":"R1","citations":["a:1"]}]}')"
v "L4 framings disagree (a broken, b holds)" "needs-human|N2" \
  "$(facts '{"links":[{"link":"L1","status":"holds"},{"link":"L2","status":"holds"},{"link":"L3","status":"holds"},{"link":"L4a","status":"broken","code":"R1","citations":["a:1"]},{"link":"L4b","status":"holds"}]}')"
v "an unsupported link"                      "needs-human|N2" \
  "$(facts '{"links":[{"link":"L1","status":"unsupported"},{"link":"L2","status":"holds"},{"link":"L3","status":"holds"},{"link":"L4a","status":"holds"},{"link":"L4b","status":"holds"}]}')"

echo ""
echo "N3 — we could not check"
v "behavioural change with no probe"  "needs-human|N3" "$(facts '{"probes":[]}')"
v "a probe that would not run"        "needs-human|N3" "$(facts '{"probes":[{"id":"p1","outcome":"unprovable"}]}')"
v "an invalid probe is still no proof" "needs-human|N3" "$(facts '{"probes":[{"id":"p1","outcome":"invalid"}]}')"
# read-only scoring is the one place a missing probe is not held against the
# change — the wave never ran, so there is nothing to hold against it.
v "read-only does not raise N3"       "accept|"        "$(facts '{"probes":[],"probes_required":false}')"

echo ""
echo "N4 — a stated rationale is a person's call, not a defect"
v "R2 + rationale becomes N4" "needs-human|N4" \
  "$(facts '{"divergence_rationale":"the RCA fix is a larger refactor","reasons":[{"id":"r1","code":"R2","citations":["a:1"],"survived":true}]}')"
v "R5 + rationale becomes N4" "needs-human|N4" \
  "$(facts '{"divergence_rationale":"the convention does not fit here","reasons":[{"id":"r1","code":"R5","citations":["a:1"],"survived":true}]}')"
v "R7 + rationale becomes N4" "needs-human|N4" \
  "$(facts '{"mode":"lintfix","behavioral":false,"probes":[],"divergence_rationale":"rule is wrong here","reasons":[{"id":"r1","code":"R7","citations":["a:1"],"survived":true}]}')"
# No explanation makes a still-crashing fix acceptable, so R1/R3/R4 never convert.
v "R1 + rationale still rejects" "reject|R1" \
  "$(facts '{"divergence_rationale":"deliberate","reasons":[{"id":"r1","code":"R1","citations":["a:1"],"survived":true}]}')"
v "R4 + rationale still rejects" "reject|R4" \
  "$(facts '{"divergence_rationale":"deliberate","reasons":[{"id":"r1","code":"R4","citations":["a:1"],"survived":true}]}')"
v "R3 + rationale still rejects" "reject|R3" \
  "$(facts '{"divergence_rationale":"deliberate","reasons":[{"id":"r1","code":"R3","citations":["a:1"],"survived":true}]}')"
# A probe beats prose: the failure still happens whatever the body says.
v "probe-proven R2 ignores the rationale" "reject|R2" \
  "$(facts '{"divergence_rationale":"deliberate","reasons":[{"id":"r1","code":"R2","citations":["a:1"],"survived":false,"probe":"proven-reject"}]}')"

echo ""
echo "N5 — the written rule and the lived practice disagree"
v "docs violated but precedent matches" "needs-human|N5" \
  "$(facts '{"standards_verdict":"violated","precedent_verdict":"matches"}')"
v "docs violated, precedent diverges too" "accept|" \
  "$(facts '{"standards_verdict":"violated","precedent_verdict":"diverges"}')"

echo ""
echo "several needs-human codes accumulate"
v "N4 and N3 together" "needs-human|N4,N3" \
  "$(facts '{"probes":[],"divergence_rationale":"deliberate","reasons":[{"id":"r1","code":"R5","citations":["a:1"],"survived":true}]}')"

echo ""
echo "the joins are keyed on the link, not the code"
# Both of these shipped. Keying on the code let one refutation speak for a
# finding it never examined, and let one proven-reject probe mark every broken
# link probe-proven -- which revives refuted findings AND suppresses the N4
# conversion, since a probe-proven reason is deliberately immune to it.
TWO_BROKEN='[{"link":"L1","status":"holds"},{"link":"L2","status":"holds"},{"link":"L3","status":"broken","code":"R3","citations":["a:1"]},{"link":"L4a","status":"holds"},{"link":"L4b","status":"broken","code":"R3","citations":["b:2"]}]'
v "a probe for one link does not back another" "needs-human|N2" \
  "$(facts "{\"links\":$TWO_BROKEN,\"reasons\":[
      {\"id\":\"L3\",\"code\":\"R3\",\"citations\":[\"a:1\"],\"survived\":false,\"probe\":\"\"},
      {\"id\":\"L4b\",\"code\":\"R3\",\"citations\":[\"b:2\"],\"survived\":false,\"probe\":\"\"}]}")"
v "a probe scoped to its own link still rejects" "reject|R3" \
  "$(facts "{\"links\":$TWO_BROKEN,\"reasons\":[
      {\"id\":\"L3\",\"code\":\"R3\",\"citations\":[\"a:1\"],\"survived\":false,\"probe\":\"proven-reject\"},
      {\"id\":\"L4b\",\"code\":\"R3\",\"citations\":[\"b:2\"],\"survived\":false,\"probe\":\"\"}]}")"
# A refuted, rationale-covered finding must reach N4 -- not be dragged into a
# reject by some other link's probe.
v "a rationale still converts when no probe backs THIS link" "needs-human|N4" \
  "$(facts '{"divergence_rationale":"deliberate","reasons":[{"id":"L2","code":"R2","citations":["a:1"],"survived":true,"probe":""}]}')"

echo ""
echo "the CLI, over a real work dir"
# `decide` is pure and easy to test; the CLI that splits its output is where a
# field-shift bug can hide, and an accept is the case that exposes it — its
# CODES field is empty.
CLI_WORK="$(mktemp -d "${TMPDIR:-/tmp}/autofix-review-cli.XXXXXX")"
mkdir -p "$CLI_WORK"/{cards,links,probes,refutations}
printf '{"mode":"bugfix","unavailable":[]}\n'          > "$CLI_WORK/cards/evidence.json"
printf '{"present":true}\n'                            > "$CLI_WORK/cards/rca.json"
printf '{"claims":[],"divergence_rationale":null}\n'   > "$CLI_WORK/cards/intent.json"
printf '{"behavioral":true,"suppression_flags":[]}\n'  > "$CLI_WORK/cards/change.json"
for l in L1 L2 L3 L4a L4b; do
    printf '{"link":"%s","status":"holds","citations":[]}\n' "$l" > "$CLI_WORK/links/$l.json"
done
printf '{"verdict":"matches"}\n'  > "$CLI_WORK/links/P.json"
printf '{"verdict":"followed"}\n' > "$CLI_WORK/links/S.json"
printf '{"id":"p1","outcome":"proven"}\n' > "$CLI_WORK/probes/p1.json"

CLI_OUT="$("$SCRIPT_DIR/verdict-rule.sh" --work "$CLI_WORK")"
cli() { printf '%s' "$CLI_OUT" | sed -n "s/^$1='\(.*\)'$/\1/p"; }
eq2() {
    local name="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$name"
    else FAIL=$((FAIL+1)); printf '  FAIL %s\n       expected: [%s]\n       actual:   [%s]\n' "$name" "$expected" "$actual"; fi
}
eq2 "VERDICT"                  accept "$(cli VERDICT)"
eq2 "CODES stays empty"        ""     "$(cli CODES)"
eq2 "SCORED does not shift"    full   "$(cli SCORED)"
eq2 "SUMMARY lands in SUMMARY" "probe-proven and every link holds" "$(cli SUMMARY)"

CLI_JSON="$("$SCRIPT_DIR/verdict-rule.sh" --work "$CLI_WORK" --json)"
eq2 "--json verdict"      accept "$(printf '%s' "$CLI_JSON" | jq -r .verdict)"
eq2 "--json codes empty"  "0"    "$(printf '%s' "$CLI_JSON" | jq -r '.codes | length')"
eq2 "--json scored"       full   "$(printf '%s' "$CLI_JSON" | jq -r .scored)"

# Empty artifact directories must read as absent facts, not as a parse error:
# a run that stopped early should reach N1 through the rule, not a stack trace.
EMPTY_WORK="$(mktemp -d "${TMPDIR:-/tmp}/autofix-review-empty.XXXXXX")"
mkdir -p "$EMPTY_WORK"/{cards,links,probes,refutations}
eq2 "an empty work dir reaches N1" "needs-human" \
    "$("$SCRIPT_DIR/verdict-rule.sh" --work "$EMPTY_WORK" --json | jq -r .verdict)"

# gather.sh records missing inputs in meta.json. The rule only read the evidence
# card's list, so a bug fix gather had already flagged as anchorless arrived
# looking complete and could reach `accept`.
META_WORK="$(mktemp -d "${TMPDIR:-/tmp}/autofix-review-meta.XXXXXX")"
cp -r "$CLI_WORK"/. "$META_WORK"/
printf '{"mode":"bugfix","unavailable":["issue"]}\n' > "$META_WORK/meta.json"
eq2 "meta.json's missing input reaches N1" "needs-human" \
    "$("$SCRIPT_DIR/verdict-rule.sh" --work "$META_WORK" --json | jq -r .verdict)"
eq2 "and it is reported as N1"            "N1" \
    "$("$SCRIPT_DIR/verdict-rule.sh" --work "$META_WORK" --json | jq -r '.codes|join(",")')"
rm -rf "$META_WORK"
rm -rf "$CLI_WORK" "$EMPTY_WORK"

echo ""
printf 'verdict-rule: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
