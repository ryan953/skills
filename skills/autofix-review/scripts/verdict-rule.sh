#!/usr/bin/env bash
# verdict-rule.sh — turn the collected link/reason/probe records into exactly one
# of accept | reject | needs-human. Pure and deterministic: no network, no model,
# no repo. Sourced by the tests, run as a CLI by the skill.
#
# The point of doing this in a script rather than "and then decide" in prose is
# that the verdict is the product. A rule the model re-derives each time is a
# rule that drifts, and a verdict that drifts is one nobody can build a habit
# around. Every branch below is asserted in verdict-rule.test.sh.
#
# Usage:
#   verdict-rule.sh --work <dir>            # assemble facts from $WORK, decide
#   verdict-rule.sh --facts <file|->        # decide over a facts JSON blob
#   . verdict-rule.sh && decide '<json>'    # the pure function, for tests
#
# Output: eval-safe KEY='value' lines —
#   VERDICT   accept | reject | needs-human
#   CODES     comma-separated R*/N* codes, most significant first ('' on accept)
#   SCORED    full | read-only     (read-only = the probe wave did not run)
#   SUMMARY   one line, for the report header

set -euo pipefail

# ---- the closed sets --------------------------------------------------------
# Membership is checked, not assumed. A subagent that invents "R9" or misspells
# a code gets its finding dropped rather than smuggled into a verdict, which is
# the conservative direction: a dropped reject costs recall, an accepted junk
# code costs precision.
REJECT_CODES="R1 R2 R3 R4 R5 R6 R7"
# Codes a stated rationale converts from "defect" to "a person's call". R1/R3/R4
# are NOT here on purpose: no amount of explanation makes "the crash still
# happens" or "you fixed one of three sites" a judgment call.
RATIONALE_CONVERTIBLE="R2 R5 R7"

is_reject_code() { case " $REJECT_CODES " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
is_convertible() { case " $RATIONALE_CONVERTIBLE " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# ---- the decision -----------------------------------------------------------
# decide <facts-json> — prints VERDICT<TAB>CODES<TAB>SCORED<TAB>SUMMARY
#
# Facts shape (see reference/cards.md for where each field comes from):
#   mode                  bugfix | lintfix
#   behavioral            true | false      — can the diff change runtime behavior
#   rca_present           true | false
#   unavailable           ["issue","diff",...] — inputs that could not be read
#   probes_required       true | false      — false in read-only scoring
#   divergence_rationale  string | null     — the author's quoted reason
#   standards_verdict     followed | violated | not-applicable
#   precedent_verdict     matches | diverges | no-precedent
#   links[]               {link,status,code,citations[]}
#   reasons[]             {id,code,citations[],survived,probe}
#   probes[]              {id,outcome}
decide() {
    local facts="$1"
    # Read one field out of the blob. Defined here so every lookup below reads
    # from the same immutable input; bash's dynamic scoping makes `$facts`
    # visible to it without threading the blob through every call.
    q() { printf '%s' "$facts" | jq -r "$1"; }

    local mode behavioral rca_present probes_required rationale std prec
    mode="$(q '.mode // "bugfix"')"
    # `// true` would be wrong here: jq's alternative operator treats `false`
    # as empty, so an explicit false would silently read back as true — and
    # `behavioral: false` is exactly the field that lets a lint fix skip the
    # probe wave. Test for null instead.
    behavioral="$(q 'if .behavioral == null then true else .behavioral end')"
    rca_present="$(q 'if .rca_present == null then true else .rca_present end')"
    probes_required="$(q 'if .probes_required == null then true else .probes_required end')"
    rationale="$(q '.divergence_rationale // ""')"
    std="$(q '.standards_verdict // "not-applicable"')"
    prec="$(q '.precedent_verdict // "no-precedent"')"

    local scored=full
    [ "$probes_required" = true ] || scored=read-only

    # -- N1: the chain has no anchor -----------------------------------------
    # Checked first because every downstream judgement is a judgement about
    # something we could not read. A reject derived from a missing input is not
    # a reject, it is a guess with a code attached.
    local link_count missing
    link_count="$(q '(.links // []) | length')"
    missing="$(q '(.unavailable // []) | map(select(. == "issue" or . == "diff")) | length')"
    if [ "$link_count" -eq 0 ] \
       || [ "$missing" -gt 0 ] \
       || { [ "$rca_present" != true ] && [ "$mode" != lintfix ]; }; then
        printf 'needs-human\tN1\t%s\tthe chain has no anchor: a required input was missing or unreadable\n' "$scored"
        return 0
    fi

    # -- filter the reasons ---------------------------------------------------
    # Three gates, each of which drops a finding rather than softening it:
    #   1. an unrecognised code is not a finding
    #   2. an uncited finding is an assertion, and assertions are not evidence
    #   3. a finding that lost its refutation, or that a probe never backed, has
    #      already been tested and failed that test
    local surviving="" converted="" i n code cites survived probe
    n="$(q '(.reasons // []) | length')"
    for ((i = 0; i < n; i++)); do
        code="$(q ".reasons[$i].code // \"\"")"
        cites="$(q "(.reasons[$i].citations // []) | length")"
        survived="$(q ".reasons[$i].survived // false")"
        probe="$(q ".reasons[$i].probe // \"\"")"

        is_reject_code "$code" || continue
        [ "$cites" -gt 0 ] || continue
        [ "$survived" = true ] || [ "$probe" = proven-reject ] || continue

        # A quoted rationale converts a convertible code to N4 — the author
        # weighed it and chose; that is a tradeoff for a human to accept or
        # not, and calling it a defect is the single easiest way to generate a
        # false reject. A probe-proven reason is immune: no rationale survives
        # a test that shows the failure still happening.
        if [ -n "$rationale" ] && is_convertible "$code" && [ "$probe" != proven-reject ]; then
            converted="$converted N4"
            continue
        fi
        surviving="$surviving $code"
    done

    # -- reject ---------------------------------------------------------------
    if [ -n "$surviving" ]; then
        local codes
        codes="$(printf '%s' "$surviving" | tr ' ' '\n' | grep -v '^$' | sort -u | paste -sd, -)"
        printf 'reject\t%s\t%s\tcited, survived refutation: %s\n' "$codes" "$scored" "$codes"
        return 0
    fi

    # -- accumulate the needs-human codes ------------------------------------
    local ncodes=""
    add_n() { case ",$ncodes," in *",$1,"*) : ;; *) ncodes="${ncodes:+$ncodes,}$1" ;; esac; }

    [ -n "$converted" ] && add_n N4

    # N5: the written rule and the lived practice disagree, so there is no
    # single documented answer to hold the diff to.
    [ "$std" = violated ] && [ "$prec" = matches ] && add_n N5

    # N2: two competent passes reached opposite conclusions. Closing-link
    # framings that disagree, or a link called broken whose reason a refuter
    # then killed. Breaking that tie is a person's job.
    local l4a l4b
    l4a="$(q '(.links // []) | map(select(.link == "L4a")) | .[0].status // ""')"
    l4b="$(q '(.links // []) | map(select(.link == "L4b")) | .[0].status // ""')"
    if { [ "$l4a" = holds ] && [ "$l4b" = broken ]; } \
       || { [ "$l4a" = broken ] && [ "$l4b" = holds ]; }; then
        add_n N2
    fi
    local refuted
    refuted="$(q '(.reasons // []) | map(select(.survived == false and .probe != "proven-reject")) | length')"
    [ "$refuted" -gt 0 ] && add_n N2

    local unsupported
    unsupported="$(q '(.links // []) | map(select(.status == "unsupported")) | length')"
    [ "$unsupported" -gt 0 ] && add_n N2

    # N3: something we could not check. Only bites when the probe wave was
    # supposed to run and a behavioural change went unproven — "we did not
    # check" and "we checked and it is fine" are different claims, and only the
    # second one earns an accept.
    if [ "$probes_required" = true ]; then
        local bad proven
        bad="$(q '(.probes // []) | map(select(.outcome == "unprovable")) | length')"
        proven="$(q '(.probes // []) | map(select(.outcome == "proven")) | length')"
        [ "$bad" -gt 0 ] && add_n N3
        [ "$behavioral" = true ] && [ "$proven" -eq 0 ] && add_n N3
    fi

    # A link still marked broken with nothing surviving to explain it.
    local broken_left
    broken_left="$(q '(.links // []) | map(select(.status == "broken")) | length')"
    [ "$broken_left" -gt 0 ] && [ -z "$ncodes" ] && add_n N2

    if [ -n "$ncodes" ]; then
        printf 'needs-human\t%s\t%s\tnot earned either way: %s\n' "$ncodes" "$scored" "$ncodes"
        return 0
    fi

    # -- accept ---------------------------------------------------------------
    # Reached only when every link holds, nothing survived, and either the
    # closing link is probe-proven or the diff cannot change behaviour at all.
    local how
    if [ "$behavioral" = false ]; then
        how="no behavioural effect; every link holds"
    elif [ "$scored" = read-only ]; then
        how="every link holds (read-only scoring: no probe was run)"
    else
        how="probe-proven and every link holds"
    fi
    printf 'accept\t\t%s\t%s\n' "$scored" "$how"
}

# ---- facts assembly ---------------------------------------------------------
# Gather the records the waves wrote into the single blob `decide` consumes.
# Missing files are absent facts, not errors: a run that stopped early should
# reach N1 through the rule, not through a stack trace.
# json_array_of <dir> <glob> — every matching file slurped into one JSON array,
# or [] when nothing matches. A plain `cat dir/*.json | jq -s .  || echo []`
# looks equivalent and is not: under `pipefail` the failing cat makes the whole
# pipeline non-zero *after* jq already printed [], so the fallback appends a
# second one and the result is two arrays glued together.
json_array_of() {
    local dir="$1" pat="$2" files=()
    # shellcheck disable=SC2231
    for f in "$dir"/$pat; do [ -e "$f" ] && files+=("$f"); done
    if [ "${#files[@]}" -eq 0 ]; then printf '[]\n'; return; fi
    cat "${files[@]}" | jq -s '.'
}

facts_from_work() {
    local work="$1" probes_required="${2:-true}"
    local cards="$work/cards" links="$work/links"

    local ev ch rc it meta
    ev="$([ -f "$cards/evidence.json" ] && cat "$cards/evidence.json" || echo '{}')"
    # gather.sh records inputs it could not read into meta.json. The evidence
    # card carries its own list too, and only the card's was being read -- so a
    # bug fix gather had already flagged as anchorless reached the rule looking
    # complete. Take the union.
    meta="$([ -f "$work/meta.json" ] && cat "$work/meta.json" || echo '{}')"
    ch="$([ -f "$cards/change.json" ]   && cat "$cards/change.json"   || echo '{}')"
    rc="$([ -f "$cards/rca.json" ]      && cat "$cards/rca.json"      || echo '{}')"
    it="$([ -f "$cards/intent.json" ]   && cat "$cards/intent.json"   || echo '{}')"

    local link_json probe_json reason_json
    link_json="$(json_array_of "$links" 'L*.json')"
    probe_json="$(json_array_of "$work/probes" '*.json')"

    # A reason is a broken link joined to the refutation that tried to kill it
    # and the probe that tried to back it. Assembled here rather than by a model
    # so the join cannot be fudged in either direction.
    #
    # BOTH joins are keyed on the link, not on the code. Keying on the code was
    # wrong in two directions at once: two links broken with the same code shared
    # whichever refutation happened to be first (so a finding the refuter killed
    # could inherit `survived` from a different finding it never examined), and
    # any single proven-reject probe marked EVERY broken link probe-proven --
    # which both revives refuted findings and suppresses the N4 rationale
    # conversion, since a probe-proven reason is deliberately immune to it.
    reason_json="$(
        printf '%s' "$link_json" | jq -c '[ .[] | select(.status == "broken") ]' | \
        jq --argjson refs "$(json_array_of "$work/refutations" '*.json')" \
           --argjson probes "$probe_json" '
            [ .[] | . as $l
              | ($refs   | map(select((.reason_id // .link // "") == ($l.link // ""))) | .[0]) as $r
              | ($probes | map(select((.link // "") == ($l.link // "")
                                      and .outcome == "proven-reject")) | .[0]) as $p
              | {id: ($l.link // "?"), code: $l.code, citations: ($l.citations // []),
                 survived: (if $r == null then false else ($r.outcome == "survived" and (($r.citations // []) | length) > 0) end),
                 probe: ($p.outcome // "")} ]'
    )"

    jq -n \
        --argjson ev "$ev" --argjson ch "$ch" --argjson rc "$rc" --argjson it "$it" \
        --argjson links "$link_json" --argjson reasons "$reason_json" --argjson probes "$probe_json" \
        --arg pr "$probes_required" --argjson meta "$meta" \
        --argjson std "$([ -f "$links/S.json" ] && cat "$links/S.json" || echo '{}')" \
        --argjson prec "$([ -f "$links/P.json" ] && cat "$links/P.json" || echo '{}')" \
        '{
            mode: ($ev.mode // $meta.mode // "bugfix"),
            behavioral: (if $ch.behavioral == null then true else $ch.behavioral end),
            rca_present: (if $rc.present == null then false else $rc.present end),
            unavailable: ((($ev.unavailable // []) + ($meta.unavailable // [])) | unique),
            probes_required: ($pr == "true"),
            divergence_rationale: ($it.divergence_rationale // null),
            standards_verdict: ($std.verdict // "not-applicable"),
            precedent_verdict: ($prec.verdict // "no-precedent"),
            links: $links, reasons: $reasons, probes: $probes
        }'
}

# ---- CLI --------------------------------------------------------------------
[ "${BASH_SOURCE[0]}" = "${0}" ] || return 0

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../../local-pr-review/scripts/lib.sh"
if [ -f "$LIB" ]; then . "$LIB"; else
    sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
    emit() { printf "%s=%s\n" "$1" "$(sq "${2-}")"; }
    die() { printf 'error: %s\n' "$*" >&2; exit 1; }
fi

WORK=""; FACTS_FILE=""; PROBES_REQUIRED=true
while [ $# -gt 0 ]; do
    case "$1" in
        --work) WORK="$2"; shift 2 ;;
        --facts) FACTS_FILE="$2"; shift 2 ;;
        --read-only) PROBES_REQUIRED=false; shift ;;
        --json) OUT_JSON=1; shift ;;
        *) die "unknown flag: $1" ;;
    esac
done

if [ -n "$FACTS_FILE" ]; then
    FACTS="$([ "$FACTS_FILE" = - ] && cat || cat "$FACTS_FILE")"
elif [ -n "$WORK" ]; then
    FACTS="$(facts_from_work "$WORK" "$PROBES_REQUIRED")"
else
    die "need --work <dir> or --facts <file|->"
fi

# Split with awk, not `read -r` with IFS=$'\t': a tab is IFS *whitespace*, so
# bash collapses consecutive tabs into one delimiter and an accept (whose CODES
# field is empty) would shift every field one to the left.
DECISION="$(decide "$FACTS")"
VERDICT="$(printf '%s' "$DECISION" | awk -F'\t' '{print $1}')"
CODES="$(printf  '%s' "$DECISION" | awk -F'\t' '{print $2}')"
SCORED="$(printf '%s' "$DECISION" | awk -F'\t' '{print $3}')"
SUMMARY="$(printf '%s' "$DECISION" | awk -F'\t' '{print $4}')"

if [ -n "${OUT_JSON:-}" ]; then
    jq -n --arg v "$VERDICT" --arg c "$CODES" --arg s "$SCORED" --arg m "$SUMMARY" \
        '{verdict: $v, codes: ($c | if . == "" then [] else split(",") end), scored: $s, summary: $m}'
else
    emit VERDICT "$VERDICT"
    emit CODES   "$CODES"
    emit SCORED  "$SCORED"
    emit SUMMARY "$SUMMARY"
fi

[ -n "$WORK" ] && printf '%s' "$FACTS" > "$WORK/facts.json"
exit 0
