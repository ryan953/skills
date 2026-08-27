#!/usr/bin/env bash
# Tests for label.sh — the ground-truth rules. Pure, no network, no repo.
#
# These matter more than they look: the labels ARE the yardstick. A label rule
# that quietly counts reviewer nits as rejects will report the skill as
# imprecise when it is behaving exactly as designed, and the fix will get made
# in the wrong place.
#
# Run:  skills/autofix-review/scripts/eval/label.test.sh
# Exit: 0 all pass, 1 any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=label.sh
. "$SCRIPT_DIR/label.sh"

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
label() { label_case "$1" | cut -f1; }

echo "merged arm"
eq "merged unchanged" ACCEPT_TRUTH \
   "$(label '{"state":"MERGED","review_decision":"APPROVED","post_review_commits":0}')"
eq "changes requested" REJECT_TRUTH \
   "$(label '{"state":"MERGED","review_decision":"CHANGES_REQUESTED","post_review_commits":2}')"
eq "comment on a file, then that file changed" REJECT_TRUTH \
   "$(label '{"state":"MERGED","review_decision":"APPROVED","post_review_commits":1,
              "review_comment_paths":["a.tsx"],"post_review_files":["a.tsx"]}')"
# A commit after review that touches nothing anyone commented on is usually the
# author's own follow-up. Calling it a response would manufacture rejects.
eq "commits after review, unrelated files" AMBIGUOUS \
   "$(label '{"state":"MERGED","review_decision":"APPROVED","post_review_commits":1,
              "review_comment_paths":["a.tsx"],"post_review_files":["b.tsx"]}')"
eq "comments but no follow-up commits" ACCEPT_TRUTH \
   "$(label '{"state":"MERGED","review_decision":"APPROVED","post_review_commits":0,
              "review_comment_paths":["a.tsx"],"post_review_files":[]}')"

echo ""
echo "closed arm — the survivorship fix"
eq "closed with a stated problem" REJECT_TRUTH \
   "$(label '{"state":"CLOSED","close_comments":[{"author":"x","body":"This is the wrong approach - it masks the error instead of fixing it."}]}')"
eq "closed after changes requested" REJECT_TRUTH \
   "$(label '{"state":"CLOSED","review_decision":"CHANGES_REQUESTED","close_comments":[]}')"
eq "closed because it stopped mattering" EXCLUDED \
   "$(label '{"state":"CLOSED","close_comments":[{"author":"x","body":"Closing, this is stale and no longer needed."}]}')"
eq "closed as a duplicate" EXCLUDED \
   "$(label '{"state":"CLOSED","close_comments":[{"author":"x","body":"duplicate of #4242"}]}')"
# The user's rule, and the honest one: with no comment we cannot judge why, so
# it is not ground truth.
eq "closed with no comment at all" EXCLUDED \
   "$(label '{"state":"CLOSED","close_comments":[]}')"
eq "closed with only whitespace" EXCLUDED \
   "$(label '{"state":"CLOSED","close_comments":[{"author":"x","body":"   \n  "}]}')"
eq "closed with a comment that names no reason" AMBIGUOUS \
   "$(label '{"state":"CLOSED","close_comments":[{"author":"x","body":"closing this one, thanks!"}]}')"

echo ""
echo "closed arm — reading the comment"
# "superseded by" plus an actual criticism is a judgement about this change that
# happens to name a replacement. Reading it as merely moot loses a real reject.
eq "superseded WITH a reason is a problem" REJECT_TRUTH \
   "$(label '{"state":"CLOSED","close_comments":[{"author":"x","body":"superseded by #99, this one does not fix the root cause"}]}')"
eq "superseded with no reason is moot" EXCLUDED \
   "$(label '{"state":"CLOSED","close_comments":[{"author":"x","body":"superseded by #99"}]}')"
# A quoted reply is someone else's words, not this commenter's reason.
eq "a quoted problem does not count" EXCLUDED \
   "$(label '{"state":"CLOSED","close_comments":[{"author":"x","body":"> this is the wrong approach\n\nagreed, closing as duplicate of #12"}]}')"
# The quote strip has to run while newlines still delimit lines. Collapsing them
# first made `> [^>]*` run to the end of the comment and eat the real reason, so
# any close that quoted something before explaining itself was silently dropped.
eq "a quote does not swallow the reason after it" REJECT_TRUTH \
   "$(label '{"state":"CLOSED","close_comments":[{"author":"x","body":"> can you take a look\n\nthis only fixes one of the call sites"}]}')"
eq "the first problem comment wins over a later moot one" REJECT_TRUTH \
   "$(label '{"state":"CLOSED","close_comments":[{"author":"a","body":"this only fixes one of the call sites"},{"author":"b","body":"stale, closing"}]}')"
eq "a moot comment does not mask a later problem one" REJECT_TRUTH \
   "$(label '{"state":"CLOSED","close_comments":[{"author":"a","body":"closing"},{"author":"b","body":"this introduces a regression in the header"}]}')"

echo ""
echo "seer arm — a bot opened it, one human decided"
eq "merged by the decider" ACCEPT_TRUTH \
   "$(label '{"arm":"seer","state":"MERGED","decided_by":"ryan953"}')"
# On this arm the close is the triage verdict, so silence still counts —
# unlike the human closed arm, where an unexplained close is not judgeable.
eq "closed unmerged, no reason given" REJECT_TRUTH \
   "$(label '{"arm":"seer","state":"CLOSED","decided_by":"ryan953","close_comments":[]}')"
eq "closed with a stated problem" REJECT_TRUTH \
   "$(label '{"arm":"seer","state":"CLOSED","decided_by":"ryan953",
              "close_comments":[{"author":"ryan953","body":"this only fixes one of the call sites"}]}')"
# The one carve-out that survives from the other arms: the fix was never judged.
eq "closed because it stopped mattering" EXCLUDED \
   "$(label '{"arm":"seer","state":"CLOSED","decided_by":"ryan953",
              "close_comments":[{"author":"ryan953","body":"issue is already fixed by #99, closing"}]}')"
eq "nobody recorded as decider" EXCLUDED \
   "$(label '{"arm":"seer","state":"CLOSED","decided_by":"","close_comments":[]}')"
# The same close on the human arm stays unjudgeable — the arms genuinely differ.
eq "the human arm still excludes a silent close" EXCLUDED \
   "$(label '{"arm":"closed","state":"CLOSED","decided_by":"ryan953","close_comments":[]}')"

echo ""
echo "seer arm — merged is not the same as correct"
# The pilot's headline finding. Without this, a fix that was merged and then
# re-fixed scores as a false reject, and the rubric gets tuned to stop finding
# real defects.
eq "merged, nothing followed it" ACCEPT_TRUTH \
   "$(label '{"arm":"seer","state":"MERGED","decided_by":"ryan953","issue_id":"SENTRY-5F52",
              "later_commits_text":"fix(other): unrelated work"}')"
eq "merged, but a later commit re-fixed the same issue" REJECT_TRUTH \
   "$(label '{"arm":"seer","state":"MERGED","decided_by":"ryan953","issue_id":"SENTRY-5F52",
              "later_commits_text":"fix(issues): Fix TypeError on save event with None in tags\n\nFixes: SENTRY-5F52."}')"
eq "no issue id means no supersession check" ACCEPT_TRUTH \
   "$(label '{"arm":"seer","state":"MERGED","decided_by":"ryan953","issue_id":"",
              "later_commits_text":"Fixes: SENTRY-5F52."}')"
eq "a different issue does not count" ACCEPT_TRUTH \
   "$(label '{"arm":"seer","state":"MERGED","decided_by":"ryan953","issue_id":"SENTRY-5F52",
              "later_commits_text":"Fixes: SENTRY-9999."}')"

echo ""
echo "classify_close_comment directly"
eq "problem vocabulary"  problem "$(classify_close_comment 'this breaks the null case')"
eq "moot vocabulary"     moot    "$(classify_close_comment 'no longer relevant')"
eq "empty"               none    "$(classify_close_comment '')"
eq "whitespace only"     none    "$(classify_close_comment '  ')"
eq "pleasantry"          unclear "$(classify_close_comment 'thanks all')"

echo ""
echo "scoreable"
scoreable ACCEPT_TRUTH && { PASS=$((PASS+1)); echo "  ok   ACCEPT_TRUTH counts"; } || { FAIL=$((FAIL+1)); echo "  FAIL ACCEPT_TRUTH counts"; }
scoreable REJECT_TRUTH && { PASS=$((PASS+1)); echo "  ok   REJECT_TRUTH counts"; } || { FAIL=$((FAIL+1)); echo "  FAIL REJECT_TRUTH counts"; }
scoreable AMBIGUOUS    && { FAIL=$((FAIL+1)); echo "  FAIL AMBIGUOUS must not count"; } || { PASS=$((PASS+1)); echo "  ok   AMBIGUOUS does not count"; }
scoreable EXCLUDED     && { FAIL=$((FAIL+1)); echo "  FAIL EXCLUDED must not count"; } || { PASS=$((PASS+1)); echo "  ok   EXCLUDED does not count"; }

echo ""
printf 'label: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
