#!/usr/bin/env bash
# Tests for classify.sh — the pure decision functions. No network, no repo, no
# tmux, so every branch of the routing table is cheap to assert.
#
# Run:  skills/local-pr-review/scripts/classify.test.sh
# Exit: 0 all pass, 1 any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=classify.sh
. "$SCRIPT_DIR/classify.sh"

PASS=0
FAIL=0

# eq <name> <expected> <actual>
eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        PASS=$((PASS+1)); printf '  ok   %s\n' "$name"
    else
        FAIL=$((FAIL+1))
        printf '  FAIL %s\n       expected: [%s]\n       actual:   [%s]\n' \
            "$name" "$expected" "$actual"
    fi
}

# eq_lines <name> <expected newline-joined> <actual newline-joined>
eq_lines() {
    local name="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        PASS=$((PASS+1)); printf '  ok   %s\n' "$name"
    else
        FAIL=$((FAIL+1))
        printf '  FAIL %s\n       expected: [%s]\n       actual:   [%s]\n' \
            "$name" "$(printf '%s' "$expected" | tr '\n' '|')" \
            "$(printf '%s' "$actual" | tr '\n' '|')"
    fi
}

echo "classify_author"
eq "my own login wins"              mine  "$(classify_author ryan953 ryan953 false feat/x)"
eq "someone else"                   other "$(classify_author ryan953 alice   false feat/x)"
eq "gh is_bot=true"                 bot   "$(classify_author ryan953 someapp true  feat/x)"
eq "[bot] suffix"                   bot   "$(classify_author ryan953 'dependabot[bot]' false x)"
eq "known bot login, is_bot false"  bot   "$(classify_author ryan953 seer-by-sentry false x)"
eq "renovate login"                 bot   "$(classify_author ryan953 renovate false x)"
eq "seer/ branch prefix"            bot   "$(classify_author ryan953 helper false seer/fix-thing)"
eq "autofix/ branch prefix"         bot   "$(classify_author ryan953 helper false autofix/nre)"
eq "dependabot/ branch prefix"      bot   "$(classify_author ryan953 helper false dependabot/npm/x)"
eq "no login at all -> other"       other "$(classify_author ryan953 '' false feat/x)"
# The reason `mine` is tested before the branch heuristic: my own seer/ branch is
# mine, not a bot's.
eq "my seer/ branch is still mine"  mine  "$(classify_author ryan953 ryan953 false seer/x)"
eq "empty me, unknown login"        other "$(classify_author '' alice false feat/x)"
eq "LPR_BOT_LOGINS extends list"    bot   "$(LPR_BOT_LOGINS=custombot classify_author ryan953 custombot false x)"
eq "LPR_BOT_LOGINS comma separated" bot   "$(LPR_BOT_LOGINS='a,custombot,b' classify_author ryan953 custombot false x)"

echo ""
echo "pane / route / iterate routing"
eq "desc pane: mine"        no  "$(wants_desc_pane mine)"
eq "desc pane: bot"         yes "$(wants_desc_pane bot)"
eq "desc pane: other"       yes "$(wants_desc_pane other)"
eq "review panes: mine"     no  "$(wants_review_panes mine)"
eq "review panes: bot"      no  "$(wants_review_panes bot)"
eq "review panes: other"    yes "$(wants_review_panes other)"
eq "route: other + PR"      comment "$(annotation_route other yes)"
eq "route: mine + PR"       apply   "$(annotation_route mine yes)"
eq "route: bot + PR"        apply   "$(annotation_route bot yes)"
# No PR means nowhere to post, so even another human's branch routes to `apply`.
eq "route: other, no PR"    apply   "$(annotation_route other no)"
eq "iterate: mine"          yes "$(iterate_ok mine)"
eq "iterate: bot"           yes "$(iterate_ok bot)"
eq "iterate: other"         no  "$(iterate_ok other)"

echo ""
echo "annotation_kind"
eq "?? anywhere"              question  "$(annotation_kind 'is this right ?? seems off')"
eq "?? leading"               question  "$(annotation_kind '?? why this file')"
eq "explain ..."              question  "$(annotation_kind 'explain what this regex does')"
eq "Explain capitalized"      question  "$(annotation_kind 'Explain the retry logic')"
eq "leading whitespace"       question  "$(annotation_kind '   why does this loop twice')"
eq "remind ..."               question  "$(annotation_kind 'remind me what calls this')"
eq "what is ..."              question  "$(annotation_kind "what is the default here")"
eq "how does ..."             question  "$(annotation_kind 'how does this get flushed')"
eq "plain directive"          directive "$(annotation_kind 'use the shared hook here')"
eq "single ? is not a question" directive "$(annotation_kind 'rename this to isReady?')"
eq "why-adjacent directive"    directive "$(annotation_kind 'the why should be in a comment')"
eq "empty text"               directive "$(annotation_kind '')"

echo ""
echo "normalize_tier"
eq "trivial"              trivial "$(normalize_tier trivial)"
eq "TRIVIAL uppercased"   trivial "$(normalize_tier TRIVIAL)"
eq "quoted + spaced"      small   "$(normalize_tier '  "small" ')"
eq "simple -> small"      small   "$(normalize_tier simple)"
eq "moderate -> medium"   medium  "$(normalize_tier moderate)"
eq "complex -> large"     large   "$(normalize_tier complex)"
eq "xl -> large"          large   "$(normalize_tier xl)"
eq "security -> risky"    risky   "$(normalize_tier security)"
# Unknown defaults to medium on purpose: over-reviewing a small change is cheap,
# under-reviewing a big one is not.
eq "garbage -> medium"    medium  "$(normalize_tier 'no idea honestly')"
eq "empty -> medium"      medium  "$(normalize_tier '')"

echo ""
echo "plan_skills"
eq_lines "trivial: nothing at all" "" "$(plan_skills trivial mine no)"
eq_lines "small, mine, backend" \
    "review" \
    "$(plan_skills small mine no)"
eq_lines "small, mine, frontend" \
    "$(printf 'review\nfrontend-conventions')" \
    "$(plan_skills small mine yes)"
eq_lines "medium, mine, frontend" \
    "$(printf 'review\nmeat-pr-review\nfrontend-conventions\nsimplify')" \
    "$(plan_skills medium mine yes)"
# `other` never gets simplify: rewriting someone else's PR is not reviewing it.
eq_lines "medium, other, frontend has no simplify" \
    "$(printf 'review\nmeat-pr-review\nfrontend-conventions')" \
    "$(plan_skills medium other yes)"
eq_lines "medium, bot counts as mine" \
    "$(printf 'review\nmeat-pr-review\nsimplify')" \
    "$(plan_skills medium bot no)"
eq_lines "large, mine, backend" \
    "$(printf 'deep-pr-review\nmeat-pr-review\nsimplify')" \
    "$(plan_skills large mine no)"
eq_lines "large, other, backend" \
    "$(printf 'deep-pr-review\nmeat-pr-review')" \
    "$(plan_skills large other no)"
eq_lines "risky, mine, frontend is the full set" \
    "$(printf 'deep-pr-review\nreview\nmeat-pr-review\nfrontend-conventions\nsimplify')" \
    "$(plan_skills risky mine yes)"
eq_lines "risky, other, backend" \
    "$(printf 'deep-pr-review\nreview\nmeat-pr-review')" \
    "$(plan_skills risky other no)"
# plan_skills is called under `set -e` in review-plan.sh, and its last statement
# is a failing `[ ... ]` test whenever frontend=no. The explicit `return 0` keeps
# an empty-ish plan from aborting the caller.
plan_skills small mine no >/dev/null
eq "exit status is 0 with frontend=no" 0 "$?"
plan_skills trivial mine no >/dev/null
eq "exit status is 0 for trivial" 0 "$?"

echo ""
echo "skill_runner / skill_mutates"
eq "meat is a script"          script "$(skill_runner meat-pr-review)"
eq "review is a skill"         skill  "$(skill_runner review)"
eq "deep-pr-review is a skill" skill  "$(skill_runner deep-pr-review)"
eq "simplify mutates"          yes "$(skill_mutates simplify)"
eq "frontend-conventions-fix mutates" yes "$(skill_mutates frontend-conventions-fix)"
eq "frontend-conventions reports"     no  "$(skill_mutates frontend-conventions)"
eq "review reports"                   no  "$(skill_mutates review)"

echo ""
echo "sync_action"
# mine/bot: stale + unapproved -> merge master in.
eq "mine, stale, unapproved"       merge-master "$(sync_action mine yes no  no)"
eq "bot, stale, unapproved"        merge-master "$(sync_action bot  yes no  no)"
# mine/bot: stale but already approved -> leave it, don't invalidate the approval.
eq "mine, stale, approved"         none         "$(sync_action mine yes no  yes)"
# mine/bot: conflicts win regardless of approval — GitHub already refuses to
# merge it either way.
eq "mine, conflicts, unapproved"   merge-master "$(sync_action mine no  yes no)"
eq "mine, conflicts, approved"     merge-master "$(sync_action mine no  yes yes)"
eq "mine, stale + conflicts"       merge-master "$(sync_action mine yes yes no)"
# mine/bot: clean and up to date -> nothing to do.
eq "mine, clean"                   none         "$(sync_action mine no  no  no)"
eq "bot, clean"                    none         "$(sync_action bot  no  no  no)"
# other: never acted on, only surfaced — stale, conflicted, or both.
eq "other, stale"                  notify       "$(sync_action other yes no  no)"
eq "other, conflicts"              notify       "$(sync_action other no  yes no)"
eq "other, stale + conflicts"      notify       "$(sync_action other yes yes no)"
eq "other, approved changes nothing" notify     "$(sync_action other yes no  yes)"
eq "other, clean"                  none         "$(sync_action other no  no  no)"

# ---------------------------------------------------------------------------
echo ""
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
