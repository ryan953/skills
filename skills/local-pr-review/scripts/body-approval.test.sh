#!/usr/bin/env bash
# Tests for the comment-body approval gate — the rule that no summary text
# reaches a PR before the user has read that exact text and approved it.
#
# This is the one part of the flow whose failure mode is public and permanent: a
# comment posted in my name on someone else's PR can't be unsent. So the tests
# assert the refusals, not just the happy path, and they run with a fake `gh` on
# PATH — if a gate ever leaks, the call is recorded in a log here instead of
# arriving in an author's inbox.
#
# Run:  skills/local-pr-review/scripts/body-approval.test.sh
# Exit: 0 all pass, 1 any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERDICT="$SCRIPT_DIR/verdict.sh"
POST="$SCRIPT_DIR/post-annotations.sh"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/body-approval-test-XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT

# job_tmp() writes rendered bodies here rather than into the real job dir.
export CLAUDE_JOB_DIR="$TMPROOT"

PASS=0
FAIL=0

# A fake gh that records instead of calling GitHub. Every test runs with this
# ahead of the real gh, so "did the gate hold?" is answerable from the log rather
# than from trust: an empty log is proof nothing was published.
GH_LOG="$TMPROOT/gh-calls.log"
mkdir -p "$TMPROOT/bin"
cat > "$TMPROOT/bin/gh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
# post-annotations.sh reads .html_url off the response
printf '{"html_url":"https://example.invalid/pull/1#pullrequestreview-1"}\n'
FAKE
chmod +x "$TMPROOT/bin/gh"
export GH_LOG
export PATH="$TMPROOT/bin:$PATH"

reset_log() { : > "$GH_LOG"; }
gh_calls() { [ -s "$GH_LOG" ] && cat "$GH_LOG" || printf ''; }

# run <script> <args...> ; sets OUT (stdout+stderr) and RC
run() { local s="$1"; shift; OUT="$(bash "$s" "$@" 2>&1)"; RC=$?; }

# val <KEY> -> the value of an emitted KEY='value' line in OUT
val() { printf '%s\n' "$OUT" | sed -n "s/^$1='\(.*\)'$/\1/p" | tail -1; }

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

echo "body_digest"
eq "stable across calls" "$(body_digest 'ship it')" "$(body_digest 'ship it')"
eq "empty body has a digest too" 12 "$(printf '%s' "$(body_digest '')" | wc -c | tr -d ' ')"
if [ "$(body_digest 'ship it')" = "$(body_digest 'ship it.')" ]; then
    FAIL=$((FAIL+1)); printf '  FAIL one character changes the digest\n'
else
    PASS=$((PASS+1)); printf '  ok   one character changes the digest\n'
fi

echo
echo "verdict.sh gate"
BODY='Looks good — two nits inline, neither blocking.'
DIGEST="$(body_digest "$BODY")"

reset_log
run "$VERDICT" --pr 1 --repo o/r --verdict comment --body "$BODY"
eq       "unapproved body refused"        1 "$RC"
contains "says why"                       "has not been approved" "$OUT"
eq       "and posted nothing"             "" "$(gh_calls)"

reset_log
run "$VERDICT" --pr 1 --repo o/r --verdict comment --body "$BODY" --body-approved deadbeef1234
eq       "wrong digest refused"           1 "$RC"
contains "says the text changed"          "does not match" "$OUT"
eq       "and posted nothing"             "" "$(gh_calls)"

reset_log
run "$VERDICT" --pr 1 --repo o/r --verdict comment --body "$BODY" --body-approved "$DIGEST"
eq       "approved body posts"            0 "$RC"
eq       "verdict recorded"               comment "$(val VERDICT)"
contains "one review call"                "pr review 1 --repo o/r --comment" "$(gh_calls)"

# request-changes requires a body, so it can never be posted unapproved either.
reset_log
run "$VERDICT" --pr 1 --repo o/r --verdict request-changes --body "$BODY"
eq       "request-changes gated too"      1 "$RC"
eq       "and posted nothing"             "" "$(gh_calls)"

# The gate is about published prose. A verdict that says nothing has nothing to
# approve, and must not be turned into a chore.
reset_log
run "$VERDICT" --pr 1 --repo o/r --verdict none
eq       "no body, no approval needed"    0 "$RC"
eq       "and nothing posted"             "" "$(gh_calls)"

reset_log
run "$VERDICT" --pr 1 --repo o/r --verdict approve --class other
eq       "bare approve needs no digest"   0 "$RC"
contains "approval still sent"            "--approve" "$(gh_calls)"

# A dry run is the sanctioned way to get a digest: it publishes nothing and hands
# back both the text to show the user and the token to pass once they agree.
reset_log
run "$VERDICT" --pr 1 --repo o/r --verdict comment --body "$BODY" --dry-run
eq       "dry run posts nothing"          "" "$(gh_calls)"
eq       "dry run digest matches"         "$DIGEST" "$(val BODY_DIGEST)"
eq       "dry run body file is readable"  "$BODY" "$(cat "$(val BODY_FILE)")"

echo
echo "post-annotations.sh gate"
ANN="$TMPROOT/annotations.md"
cat > "$ANN" <<'EOF'
## src/app.tsx:43 (+)
use the shared hook here

## config.ts (file-level)
this file does not belong in the diff
EOF

reset_log
run "$POST" --pr 7 --repo o/r --out "$ANN" --body 'Notes from a local pass.'
eq       "unapproved review refused"      1 "$RC"
contains "says why"                       "has not been approved" "$OUT"
eq       "and posted nothing"             "" "$(gh_calls)"

reset_log
run "$POST" --pr 7 --repo o/r --out "$ANN" --body 'Notes from a local pass.' --dry-run
eq       "dry run posts nothing"          "" "$(gh_calls)"
FULL_DIGEST="$(val BODY_DIGEST)"
FULL_BODY_FILE="$(val BODY_FILE)"
contains "body file has the framing"      "Notes from a local pass." "$(cat "$FULL_BODY_FILE")"
contains "body file folds in file notes"  "does not belong in the diff" "$(cat "$FULL_BODY_FILE")"

# The digest covers the body as sent, not the --body argument. Approving the
# framing alone would approve less text than the author would actually receive —
# the file-level notes get appended after it.
reset_log
run "$POST" --pr 7 --repo o/r --out "$ANN" --body 'Notes from a local pass.' \
    --body-approved "$(body_digest 'Notes from a local pass.')"
eq       "framing-only digest refused"    1 "$RC"
contains "says the text changed"          "does not match" "$OUT"
eq       "and posted nothing"             "" "$(gh_calls)"

reset_log
run "$POST" --pr 7 --repo o/r --out "$ANN" --body 'Notes from a local pass.' \
    --body-approved "$FULL_DIGEST"
eq       "approved review posts"          0 "$RC"
eq       "posted flag set"                yes "$(val POSTED)"
eq       "one inline comment"             1 "$(val LINE_COMMENTS)"
contains "one reviews API call"           "api repos/o/r/pulls/7/reviews" "$(gh_calls)"

# Nothing to post means nothing to approve: the early exit must not demand a
# digest for a review that was never going to be created.
reset_log
: > "$TMPROOT/empty.md"
run "$POST" --pr 7 --repo o/r --out "$TMPROOT/empty.md" --body 'Notes.'
eq       "empty annotations exit clean"   0 "$RC"
eq       "posted flag unset"              no "$(val POSTED)"
eq       "and posted nothing"             "" "$(gh_calls)"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
