#!/usr/bin/env bash
# Does the "why was this closed" window actually exclude older comments?
#
# It did not, off GNU. The window came from `date -u -d "$closedAt -1 day"`.
# `-d` is a GNU flag; BSD (macOS) `date` rejects it, the error was sent to
# /dev/null, and the window came out empty. An empty window does not widen the
# filter, it removes it: `.createdAt >= ""` is true of every string. So every
# comment a PR had ever received was collected as a reason for its close, and a
# review note from months earlier became the recorded explanation for closing
# it -- corrupting the ground truth this whole evaluation is scored against, in
# the direction that makes an unexplained close look explained.
#
# The filter is extracted from slice.sh, not restated here: a copy would keep
# passing after slice.sh drifted away from it.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SLICE="$HERE/slice.sh"
BOTS_RE='\[bot\]$|^codecov|^sentry-io|^getsentry-bot|^seer-by-sentry|^github-actions'

block="$(sed -n '/^#>>> close-window$/,/^#<<< close-window$/p' "$SLICE")"
[ -n "$block" ] || { echo "FAIL: close-window markers missing from slice.sh"; exit 1; }
CLOSE_COMMENTS_JQ=""
eval "$block"
[ -n "$CLOSE_COMMENTS_JQ" ] || { echo "FAIL: CLOSE_COMMENTS_JQ came out empty"; exit 1; }

# Closed 2026-08-20. The window must start at midnight on the 19th, so the
# evening-before comment survives and the June one does not.
raw='{
  "closedAt": "2026-08-20T14:22:31Z",
  "comments": [
    {"author":{"login":"reviewer"},"createdAt":"2026-06-01T10:00:00Z","body":"this only fixes one call site"},
    {"author":{"login":"reviewer"},"createdAt":"2026-08-19T23:50:00Z","body":"closing, superseded by #123"},
    {"author":{"login":"codecov[bot]"},"createdAt":"2026-08-20T09:00:00Z","body":"coverage fell"}
  ]}'

got="$(printf '%s' "$raw" | jq -c --arg bots "$BOTS_RE" "$CLOSE_COMMENTS_JQ")" || {
    echo "FAIL: the filter did not run"; exit 1; }
n="$(printf '%s' "$got" | jq 'length')"

[ "$n" = 1 ] || { echo "FAIL: expected 1 comment in the window, got $n: $got"; exit 1; }
printf '%s' "$got" | grep -qF 'superseded by #123' \
  || { echo "FAIL: the real closing reason was dropped: $got"; exit 1; }
printf '%s' "$got" | grep -qF 'only fixes one call site' \
  && { echo "FAIL: a June comment was read as the reason for an August close"; exit 1; }
echo "ok: only comments from the day before the close onwards are collected"

printf '%s' "$got" | grep -qF 'coverage fell' \
  && { echo "FAIL: a bot comment leaked into the closing reasons"; exit 1; }
echo "ok: bots are still excluded"

# The regression itself: prove the empty window is not a harmless fallback.
# This is what the GNU-only `date` left behind, and it takes everything.
broken="$(printf '%s' "$raw" | jq -c --arg bots "$BOTS_RE" --arg window "" '
    [ (.comments // [])[]
      | select(((.author.login // "") | test($bots)) | not)
      | select(.createdAt >= $window)
      | {author: (.author.login // ""), body: (.body // "")} ]')"
[ "$(printf '%s' "$broken" | jq 'length')" = 2 ] \
  || { echo "FAIL: the empty-window case no longer reproduces; this test proves nothing"; exit 1; }
echo "ok: an empty window would take 2 of 2 -- the filter must never produce one"

# No `closedAt` has always meant "take everything"; keep it that way.
n2="$(printf '%s' '{"closedAt":null,"comments":[{"author":{"login":"a"},"createdAt":"2020-01-01T00:00:00Z","body":"x"}]}' \
      | jq --arg bots "$BOTS_RE" "$CLOSE_COMMENTS_JQ" | jq 'length')"
[ "$n2" = 1 ] || { echo "FAIL: a missing closedAt should keep every comment, got $n2"; exit 1; }
echo "ok: a missing closedAt still keeps every comment"

# A malformed timestamp must not kill the slice.
n3="$(printf '%s' '{"closedAt":"not-a-date","comments":[{"author":{"login":"a"},"createdAt":"2020-01-01T00:00:00Z","body":"x"}]}' \
      | jq --arg bots "$BOTS_RE" "$CLOSE_COMMENTS_JQ" 2>/dev/null | jq 'length')" || n3=err
[ "$n3" = 1 ] || { echo "FAIL: a malformed closedAt broke the filter (got $n3)"; exit 1; }
echo "ok: a malformed closedAt degrades instead of throwing"

# The class of bug, not just this instance: GNU-only `date` in scripts that are
# meant to run on macOS, where the flag is rejected and the error is often
# swallowed. `date -d` and `date --date` are the two spellings.
SCRIPTS="$(cd "$HERE/.." && pwd)"
if grep -rnE '\bdate\b[^|]*(-d |--date)' "$SCRIPTS" --include='*.sh' \
     | grep -vE ':[0-9]+:[[:space:]]*#' \
     | grep -v 'close-window\.test\.sh'; then
    echo "FAIL: GNU-only \`date -d\` is back; use jq's fromdateiso8601 instead"; exit 1
fi
echo "ok: no GNU-only date syntax in any script (5 checks passed)"
