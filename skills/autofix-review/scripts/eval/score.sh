#!/usr/bin/env bash
# score.sh — the confusion matrix and the two numbers the design is optimised for.
#
# Reject precision:  of the changes we rejected, how many did a human also reject?
# Accept precision:  of the changes we accepted, how many stood as written?
#
# Recall is reported but is not the target. needs-human is not a wrong answer —
# it is the designed fallback — so it is counted separately and never folded into
# either precision. Reporting it as a miss would create pressure to guess, which
# is the one thing that would make these numbers stop meaning anything.
#
# Usage:
#   score.sh --predictions predictions.jsonl [--by-arm] [--reasons reasons.tsv]

set -euo pipefail

PRED=""; BY_ARM=""; REASONS=""
while [ $# -gt 0 ]; do
    case "$1" in
        --predictions) PRED="$2"; shift 2 ;;
        --by-arm) BY_ARM=1; shift ;;
        --reasons) REASONS="$2"; shift 2 ;;
        *) printf 'unknown flag: %s\n' "$1" >&2; exit 1 ;;
    esac
done
[ -n "$PRED" ] || { printf 'need --predictions <file.jsonl>\n' >&2; exit 1; }

report() {   # report <label> <jsonl>
    local title="$1" data="$2"
    local n tp fp tn fn nh_r nh_a rp ap
    # Only labelled cases can move a number; AMBIGUOUS and EXCLUDED are counted
    # separately at the end so the denominator here stays honest.
    n="$(printf '%s' "$data" | jq -s '[ .[] | select(.label == "ACCEPT_TRUTH" or .label == "REJECT_TRUTH") ] | length')"
    [ "$n" -gt 0 ] || { printf '\n%s: no scored cases\n' "$title"; return; }

    cnt() { printf '%s' "$data" | jq -s --arg p "$1" --arg l "$2" \
        '[ .[] | select(.predicted == $p and .label == $l) ] | length'; }
    tp="$(cnt reject REJECT_TRUTH)"      # we rejected, a human rejected
    fp="$(cnt reject ACCEPT_TRUTH)"      # we rejected, it stood as written
    tn="$(cnt accept ACCEPT_TRUTH)"
    fn="$(cnt accept REJECT_TRUTH)"      # we accepted something a human sent back
    nh_r="$(cnt needs-human REJECT_TRUTH)"
    nh_a="$(cnt needs-human ACCEPT_TRUTH)"

    pct() { [ "$2" -eq 0 ] && printf 'n/a' || printf '%d%%' $(( $1 * 100 / $2 )); }
    rp="$(pct "$tp" $((tp + fp)))"
    ap="$(pct "$tn" $((tn + fn)))"

    printf '\n%s  (%s scored cases)\n' "$title" "$n"
    printf '                     human: reject   human: accept\n'
    printf '  we reject          %13s   %13s\n' "$tp" "$fp"
    printf '  we accept          %13s   %13s\n' "$fn" "$tn"
    printf '  we say needs-human %13s   %13s\n' "$nh_r" "$nh_a"
    printf '\n  reject precision   %s   (%s of %s)\n' "$rp" "$tp" "$((tp + fp))"
    printf '  accept precision   %s   (%s of %s)\n' "$ap" "$tn" "$((tn + fn))"
    printf '  deferred to a human %d%% of the time\n' $(( (nh_r + nh_a) * 100 / n ))

    # The actionable half. A false reject is a bug in exactly one taxonomy code,
    # and this is what says which — without it you end up tuning the whole
    # rubric on the evidence of a single bad call.
    local fps
    fps="$(printf '%s' "$data" | jq -sr '
        [ .[] | select(.predicted == "reject" and .label == "ACCEPT_TRUTH") ]
        | map(.predicted_codes // []) | add // [] | group_by(.) | map({code: .[0], n: length})
        | sort_by(-.n) | .[] | "    \(.code)  \(.n)"')"
    if [ -n "$fps" ]; then
        printf '\n  false rejects by code (fix the code, not the verdict):\n%s\n' "$fps"
    fi

    local nhs
    nhs="$(printf '%s' "$data" | jq -sr '
        [ .[] | select(.predicted == "needs-human") ]
        | map(.predicted_codes // []) | add // [] | group_by(.) | map({code: .[0], n: length})
        | sort_by(-.n) | .[] | "    \(.code)  \(.n)"')"
    if [ -n "$nhs" ]; then printf '\n  deferrals by code:\n%s\n' "$nhs"; fi

    local ro
    ro="$(printf '%s' "$data" | jq -s '[ .[] | select(.scored == "read-only") ] | length')"
    if [ "$ro" -gt 0 ]; then
        printf '\n  NOTE: %s of these were scored read-only (no probe wave). Do not\n        average them with fully-scored runs — the closing link was read,\n        not measured.\n' "$ro"
    fi
}

ALL="$(cat "$PRED")"
report "OVERALL" "$ALL"

if [ -n "$BY_ARM" ]; then
    # Whatever arms the data actually contains, not a hardcoded pair. The list
    # was `merged closed`, so `--by-arm` reported "no scored cases" for the seer
    # arm -- the one the README and RUNBOOK both say to start with.
    ARMS="$(printf '%s' "$ALL" | jq -sr '[ .[].arm // empty ] | unique | .[]')"
    for arm in $ARMS; do
        report "ARM: $arm" "$(printf '%s' "$ALL" | jq -c --arg a "$arm" 'select(.arm == $a)')"
    done
fi

# Verdict-vs-reason is a judgement call, so it is laid out for a person rather
# than scored by a regex: agreeing on "reject" for the wrong reason is a worse
# result than the matrix above can show.
if [ -n "$REASONS" ]; then
    printf '%s' "$ALL" | jq -sr '
        .[] | select(.label == "REJECT_TRUTH")
        | [ (.pr|tostring), .predicted, ((.predicted_codes // []) | join("+")),
            (.predicted_summary // ""), (.label_why // "") ] | @tsv' > "$REASONS"
    printf '\nreason comparison for the true rejects -> %s\n' "$REASONS"
    printf '  columns: pr, our verdict, our codes, our summary, what the human actually said\n'
    printf '  read these by hand. A right verdict for the wrong reason is a miss.\n'
fi

printf '\ncases that never entered the numbers:\n'
printf '%s' "$ALL" | jq -sr '[ .[] | select(.label == "AMBIGUOUS" or .label == "EXCLUDED") ]
    | group_by(.label) | .[] | "  \(.[0].label)  \(length)"' 2>/dev/null || true
