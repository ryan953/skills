#!/usr/bin/env bash
# Tests for review-plan.sh — the tier -> skills -> cache-path plan.
#
# classify.test.sh already covers which skills a tier implies; what's tested here
# is the part that can silently cost money or leak edits into someone else's PR:
# cache hit/miss accounting, --refresh, --only/--add/--skip, and the refusal to
# plan a mutating skill on another human's work even when asked explicitly.
#
# Run:  skills/local-pr-review/scripts/review-plan.test.sh
# Exit: 0 all pass, 1 any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLAN="$SCRIPT_DIR/review-plan.sh"

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/review-plan-test-XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0
FAIL=0

# cache -> a fresh empty cache dir. mktemp, not a counter: this runs in `$(...)`,
# so a counter increment would be lost to the subshell and every "fresh" dir
# would be the same one carrying the previous test's cache files.
cache() { mktemp -d "$TMPROOT/cache-XXXXXX"; }

# run <args...> ; sets OUT
run() { OUT="$(bash "$PLAN" "$@" 2>&1)"; RC=$?; }

# field <col> -> that column of OUT, newline-joined
field() { printf '%s\n' "$OUT" | awk -F'\t' -v c="$1" 'NF{print $c}'; }

eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        PASS=$((PASS+1)); printf '  ok   %s\n' "$name"
    else
        FAIL=$((FAIL+1))
        printf '  FAIL %s\n       expected: [%s]\n       actual:   [%s]\n' \
            "$name" "$(printf '%s' "$expected" | tr '\n\t' '|>')" \
            "$(printf '%s' "$actual" | tr '\n\t' '|>')"
    fi
}

contains() {
    local name="$1" sub="$2" hay="$3"
    case "$hay" in
        *"$sub"*) PASS=$((PASS+1)); printf '  ok   %s\n' "$name" ;;
        *) FAIL=$((FAIL+1)); printf '  FAIL %s\n       want substr: [%s]\n       in:          [%s]\n' \
               "$name" "$sub" "$(printf '%s' "$hay" | tr '\n\t' '|>')" ;;
    esac
}

echo "plan shape"
C="$(cache)"
run --tier medium --class mine --frontend no --cache-dir "$C" --pr 42
eq "medium/mine/backend skills" \
    "$(printf 'review\nmeat-pr-review\nsimplify')" "$(field 1)"
eq "all miss on an empty cache" \
    "$(printf 'miss\nmiss\nmiss')" "$(field 4)"
eq "cache paths are per-skill under --cache-dir" \
    "$(printf '%s/review-review.md\n%s/review-meat-pr-review.md\n%s/review-simplify.md' "$C" "$C" "$C")" \
    "$(field 3)"
eq "runner: meat is a script, the rest are skills" \
    "$(printf 'skill\nscript\nskill')" "$(field 2)"
contains "skill command is the slash form" "/review" "$OUT"
contains "meat command is runnable and redirects to the cache" \
    "> '$C/review-meat-pr-review.md'" "$OUT"
contains "meat command passes the PR number" "review.sh' '42'" "$OUT"

echo ""
echo "cache hits"
C="$(cache)"
printf 'previous findings\n' > "$C/review-review.md"
run --tier small --class mine --frontend no --cache-dir "$C" --pr 42
eq "a non-empty cache file is a hit" hit "$(field 4)"
contains "hit says to read it" "cached; read it" "$OUT"
eq "a hit carries no command" "" "$(printf '%s\n' "$OUT" | awk -F'\t' 'NF{print $5}')"

# An empty file is a failed run, not a review: it must not count as a hit.
C="$(cache)"
: > "$C/review-review.md"
run --tier small --class mine --frontend no --cache-dir "$C" --pr 42
eq "an empty cache file is a miss" miss "$(field 4)"

C="$(cache)"
printf 'stale\n' > "$C/review-review.md"
run --tier small --class mine --frontend no --cache-dir "$C" --pr 42 --refresh
eq "--refresh forces a miss" miss "$(field 4)"

echo ""
echo "selection flags"
C="$(cache)"
run --tier risky --class mine --frontend yes --cache-dir "$C" --pr 42 --skip meat-pr-review --skip simplify
eq "--skip removes planned skills" \
    "$(printf 'deep-pr-review\nreview\nfrontend-conventions')" "$(field 1)"

C="$(cache)"
run --tier small --class mine --frontend no --cache-dir "$C" --pr 42 --add html-review
eq "--add appends to the tier's plan" \
    "$(printf 'review\nhtml-review')" "$(field 1)"

C="$(cache)"
run --tier risky --class mine --frontend yes --cache-dir "$C" --pr 42 --only review
eq "--only replaces the plan entirely" review "$(field 1)"

C="$(cache)"
run --tier medium --class mine --frontend no --cache-dir "$C" --pr 42 --add review
eq "duplicates are collapsed" \
    "$(printf 'review\nmeat-pr-review\nsimplify')" "$(field 1)"

echo ""
echo "guards"
# The important one: plan_skills won't plan simplify for `other`, but --add and
# --only bypass plan_skills, so review-plan.sh has to refuse it on its own.
C="$(cache)"
run --tier medium --class other --frontend no --cache-dir "$C" --pr 42 --add simplify
eq "simplify is refused for someone else's PR" \
    "$(printf 'review\nmeat-pr-review\nsimplify')" "$(field 1)"
eq "  ...and marked skip, not miss" \
    "$(printf 'miss\nmiss\nskip')" "$(field 4)"
contains "  ...with the reason" "mutates code, and this is someone else's PR" "$OUT"

C="$(cache)"
run --tier medium --class other --frontend no --cache-dir "$C" --pr 42 --only simplify
eq "--only simplify on another's PR is still refused" skip "$(field 4)"

# No PR number is not a skip: meat abridges the local branch instead, so an
# unpushed branch still gets a reading diff.
C="$(cache)"
run --tier medium --class mine --frontend no --cache-dir "$C"
eq "meat still runs without a PR" \
    "$(printf 'miss\nmiss\nmiss')" "$(field 4)"
contains "  ...in local mode" "review.sh' --local" "$OUT"
contains "  ...and says so" "reading diff (local branch)" "$OUT"

echo ""
echo "trivial tier"
C="$(cache)"
run --tier trivial --class mine --frontend yes --cache-dir "$C" --pr 42
eq "trivial plans nothing" '#' "$(field 1)"
contains "trivial explains that reading the diff is the review" \
    "read the diff directly" "$OUT"
eq "trivial still exits 0" 0 "$RC"

echo ""
echo "tier normalization + errors"
C="$(cache)"
run --tier COMPLEX --class mine --frontend no --cache-dir "$C" --pr 42
eq "an unnormalized tier is normalized (COMPLEX -> large)" \
    "$(printf 'deep-pr-review\nmeat-pr-review\nsimplify')" "$(field 1)"

C="$(cache)"
run --tier 'who knows' --class mine --frontend no --cache-dir "$C" --pr 42
eq "an unknown tier falls back to medium" \
    "$(printf 'review\nmeat-pr-review\nsimplify')" "$(field 1)"

run --tier small --class mine --frontend no --pr 42
eq "--cache-dir is required" 1 "$RC"
contains "  ...and says so" "--cache-dir is required" "$OUT"

run --tier small --cache-dir "$(cache)" --nonsense
eq "an unknown flag exits non-zero" 1 "$RC"

# A cache dir that doesn't exist yet is created, not an error: the flow calls this
# before anything has written a report.
C="$TMPROOT/not-yet-created"
run --tier small --class mine --frontend no --cache-dir "$C" --pr 42
eq "a missing cache dir is created" 0 "$RC"
[ -d "$C" ] && eq "  ...and now exists" yes yes || eq "  ...and now exists" yes no

# ---------------------------------------------------------------------------
echo ""
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
