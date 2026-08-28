#!/usr/bin/env bash
# Tests for gather.sh — against real throwaway git repos, no network and no gh.
#
# extract.test.sh covers the parsing in isolation; this covers the part that only
# a real repo can: that the diff is taken against the *merge-base* and not the
# base branch's moving tip, and that a missing input is reported rather than
# crashed on.
#
# Run:  skills/autofix-review/scripts/gather.test.sh
# Exit: 0 all pass, 1 any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GATHER="$SCRIPT_DIR/gather.sh"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/autofix-review-gather.XXXXXX")"
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
contains() {
    local name="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) PASS=$((PASS+1)); printf '  ok   %s\n' "$name" ;;
        *) FAIL=$((FAIL+1)); printf '  FAIL %s\n       missing: [%s]\n' "$name" "$needle" ;;
    esac
}

# new_repo <name> — a repo with a `main` and one commit, git identity set so the
# test does not depend on the runner's global git config.
new_repo() {
    local d="$TMPROOT/$1"
    mkdir -p "$d"
    git -C "$d" init -q -b main
    git -C "$d" config user.email test@example.com
    git -C "$d" config user.name  Test
    printf 'const a = 1;\n' > "$d/app.ts"
    git -C "$d" add -A && git -C "$d" commit -qm 'init'
    printf '%s\n' "$d"
}

echo "a bug fix on a feature branch"
R="$(new_repo bugfix)"
git -C "$R" checkout -qb fix/null-org
printf 'const a = org?.id ?? null;\n' > "$R/app.ts"
git -C "$R" add -A
git -C "$R" commit -qm 'fix(org): guard null organization

Fixes https://sentry.sentry.io/issues/6789012/'
# Master moves on after the branch forked. Everything below must be blind to it.
git -C "$R" checkout -q main
printf 'unrelated\n' > "$R/other.ts"
git -C "$R" add -A && git -C "$R" commit -qm 'feat: unrelated work on main'
git -C "$R" checkout -q fix/null-org

W="$TMPROOT/work-bugfix"
OUT="$("$GATHER" --repo-path "$R" --work "$W" 2>&1)"
eval "$OUT"

eq "mode is bugfix"            bugfix "$MODE"
eq "one issue reference"       1      "$REF_COUNT"
eq "one changed file"          1      "$FILE_COUNT"
# A REFERENCE is not the issue. This fixture cites an issue URL and says nothing
# else, and gather cannot fetch the tracker -- so there is no anchor, and saying
# so here is what stops the card writers being promised text no file contains.
# Claiming `issue` on the reference alone is what sent 13 of 20 cases in a real
# run to needs-human/N1 after a full review that never had anything to read.
eq "a bare reference is not an anchor" "issue" "$UNAVAILABLE"
eq "and the source is none"            none    "$EVIDENCE_SOURCE"
contains "the sentry url is captured" "sentry	https://sentry.sentry.io/issues/6789012" "$(cat "$REFS_FILE")"

# The load-bearing assertion: the base is the fork point, so the commit that
# landed on main afterwards is not part of the change under review.
eq "base is the merge-base, not main's tip" \
   "$(git -C "$R" rev-parse main~1)" "$BASE_SHA"
eq "the diff is only this branch's file" "app.ts" "$(cat "$FILES_FILE")"
case "$(cat "$DIFF_FILE")" in
    *other.ts*) FAIL=$((FAIL+1)); printf '  FAIL main-only work leaked into the diff\n' ;;
    *) PASS=$((PASS+1)); printf '  ok   main-only work stayed out of the diff\n' ;;
esac
contains "the commit message reaches body.md" "guard null organization" "$(cat "$BODY_FILE")"

echo ""
echo "a lint fix with no issue"
R2="$(new_repo lintfix)"
git -C "$R2" checkout -qb ref/lint
printf '// eslint-disable-next-line no-console\nconsole.log(1);\n' > "$R2/app.ts"
git -C "$R2" add -A && git -C "$R2" commit -qm 'ref(lint): silence no-console'
W2="$TMPROOT/work-lintfix"
eval "$("$GATHER" --repo-path "$R2" --work "$W2" 2>&1)"

eq "mode is lintfix"              lintfix "$MODE"
eq "no issue references"          0       "$REF_COUNT"
contains "the suppression is recorded" "suppress	eslint:" "$(cat "$LINT_FILE")"
# lintfix mode needs no issue, so a missing one is not reported as missing —
# that is what keeps every lint fix from landing on N1.
eq "a missing issue is not flagged in lintfix mode" "" "$UNAVAILABLE"

echo ""
echo "a bug fix with no issue anywhere"
R3="$(new_repo anchorless)"
git -C "$R3" checkout -qb fix/mystery
printf 'const a = 2;\n' > "$R3/app.ts"
git -C "$R3" add -A && git -C "$R3" commit -qm 'fix: something'
W3="$TMPROOT/work-anchorless"
eval "$("$GATHER" --repo-path "$R3" --work "$W3" 2>&1)"

eq "still classified as a bug fix" bugfix "$MODE"
# The chain has no anchor and gather says so, rather than letting a later wave
# quietly review the diff against nothing.
eq "the missing issue is reported"  issue  "$UNAVAILABLE"
eq "meta.json carries it too" "issue" \
   "$(jq -r '.unavailable | join(",")' "$W3/meta.json")"

echo ""
echo "evidence written into the description, with no tracker link"
R5="$(new_repo bodyevidence)"
git -C "$R5" checkout -qb fix/from-body
printf 'const a = 3;\n' > "$R5/app.ts"
git -C "$R5" add -A && git -C "$R5" commit -qm 'fix(app): use the fork point

## Bug

The base ref was the branch tip rather than the fork point.
TypeError: cannot read length of undefined

Reproduced on a branch 400 commits behind.'
W5="$TMPROOT/work-bodyevidence"
eval "$("$GATHER" --repo-path "$R5" --work "$W5" 2>&1)"

eq "no tracker reference"          0         "$REF_COUNT"
# A self-documenting fix is not an anchorless one. Sending these to N1 would
# defer exactly the changes that came with the most explanation.
eq "evidence comes from the body"  pr-body   "$EVIDENCE_SOURCE"
eq "so nothing is reported missing" ""       "$UNAVAILABLE"
contains "the Bug section is recorded" "section	## Bug" "$(cat "$W5/raw/body-evidence.txt")"
eq "meta.json carries the source" pr-body \
   "$(jq -r .evidence_source "$W5/meta.json")"

echo ""
echo "a bug fix with no evidence anywhere still reaches N1"
eval "$("$GATHER" --repo-path "$R3" --work "$TMPROOT/work-anchorless2" 2>&1)"
eq "evidence source is none" none  "$EVIDENCE_SOURCE"
eq "and the gap is reported" issue "$UNAVAILABLE"

echo ""
echo "a deliberate departure, stated in the framing"
R6="$(new_repo divergence)"
git -C "$R6" checkout -qb fix/narrow
printf 'const a = 4;\n' > "$R6/app.ts"
git -C "$R6" add -A && git -C "$R6" commit -qm 'fix(app): narrow guard

## Bug

TypeError: cannot read id of undefined

Surfaced from JAVASCRIPT-1ABC, but does not directly address its root cause -
the wider refactor is out of scope for this PR.'
W6="$TMPROOT/work-divergence"
eval "$("$GATHER" --repo-path "$R6" --work "$W6" 2>&1)"
contains "the departure is captured for the intent writer" \
   "does not directly address its root cause" "$(cat "$DIVERGENCE_FILE")"
# It must NOT fire on an ordinary fix, or every change would look like a
# tradeoff and N4 would swallow real defects.
eval "$("$GATHER" --repo-path "$R5" --work "$TMPROOT/work-nodiv" 2>&1)"
eq "silent on an ordinary fix" "" "$(cat "$DIVERGENCE_FILE")"

echo ""
echo "repo docs discovery"
R4="$(new_repo docs)"
mkdir -p "$R4/static/app"
printf '# root rules\n' > "$R4/CLAUDE.md"
printf '# app rules\n' > "$R4/static/app/CLAUDE.md"
git -C "$R4" add -A && git -C "$R4" commit -qm 'add docs'
git -C "$R4" checkout -qb fix/deep
printf 'x\n' > "$R4/static/app/foo.ts"
git -C "$R4" add -A && git -C "$R4" commit -qm 'fix: deep file'
W4="$TMPROOT/work-docs"
eval "$("$GATHER" --repo-path "$R4" --work "$W4" 2>&1)"

eq "both governing docs found" 2 "$DOC_COUNT"
contains "the root doc"      "CLAUDE.md"              "$(cat "$DOCS_FILE")"
contains "the nearest doc"   "static/app/CLAUDE.md"   "$(cat "$DOCS_FILE")"

echo ""
echo ""
echo "where the evidence is allowed to come from"

# A description that states the cause IS an anchor -- the weak one. Seer writes
# it in prose ("The root cause was ...", "The issue was that ..."), never under a
# heading, which is why the heading-only extractor found nothing in autofix PRs.
R2="$(new_repo prose)"
git -C "$R2" checkout -qb fix/prose
printf 'const a = org?.id ?? null;\n' > "$R2/app.ts"
git -C "$R2" add -A
git -C "$R2" commit -qm 'fix(org): guard null organization

Fixes https://sentry.sentry.io/issues/6789012/. The root cause was that
getOrg() returns undefined for deleted orgs, so the caller dereferenced it.'
git -C "$R2" checkout -q main; git -C "$R2" checkout -q fix/prose
W2="$TMPROOT/work-prose"
eval "$("$GATHER" --repo-path "$R2" --work "$W2" 2>&1)"
eq "a cause stated in prose is evidence" pr-body "$EVIDENCE_SOURCE"
eq "so nothing is missing"               ""      "$UNAVAILABLE"

# And the strong case: the caller reached the tracker and handed us the text.
ISSUE="$TMPROOT/issue.md"
printf '# ORG-1 null org crash\n\nStack: TypeError at getOrg\n' > "$ISSUE"
W3="$TMPROOT/work-issue"
eval "$("$GATHER" --repo-path "$R2" --work "$W3" --issue-file "$ISSUE" 2>&1)"
eq "issue text makes the source issue" issue "$EVIDENCE_SOURCE"
eq "and it is kept for the writers"    yes   "$([ -s "$W3/raw/issue.md" ] && echo yes || echo no)"

printf 'gather: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
