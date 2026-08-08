#!/usr/bin/env bash
# post-annotations.sh — turn revdiff annotations on someone else's PR into a
# single GitHub review with inline comments on the lines they were written on.
#
# One review, not N comments: `gh api .../reviews` with event=COMMENT posts the
# whole set as one notification, in one place, in diff order. Posting each
# annotation as its own comment would spam the author's inbox and scatter the
# feedback across the timeline.
#
# Two things are deliberately never posted:
#   * questions (`??` / "explain ...") — asking myself a question and publishing
#     it to the author's PR are different acts; those get answered in chat.
#   * file-level notes — GitHub has no line to hang them on, so they're folded
#     into the review body instead of being dropped.
#
# The review body is a summary the model wrote, not something the user typed, so
# it never reaches the PR unposted-unseen: --body-approved carries the digest of
# the exact text the user approved, and a real post without it is refused. The
# inline comments are the user's own annotations, quoted back; approving the body
# approves the review that carries them.
#
# Usage:
#   post-annotations.sh --pr <n> --out <annotations-file> [--repo owner/name]
#                       [--commit <sha>] [--body <text>] [--dry-run]
#                       [--body-approved <digest>]
#
# --dry-run prints the exact payload, writes the rendered body to BODY_FILE with
# its BODY_DIGEST, and posts nothing. It is the required first call: without a
# matching --body-approved there is no way to post.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

PR="" OUT="" REPO="" COMMIT="" BODY="" DRY=no APPROVED=""
while [ $# -gt 0 ]; do
    case "$1" in
        --pr) PR="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --repo) REPO="$2"; shift 2 ;;
        --commit) COMMIT="$2"; shift 2 ;;
        --body) BODY="$2"; shift 2 ;;
        --body-approved) APPROVED="$2"; shift 2 ;;
        --dry-run) DRY=yes; shift ;;
        *) die "unknown argument: $1" ;;
    esac
done
[ -n "$PR" ] || die "--pr <number> is required"
[ -n "$OUT" ] || die "--out <annotations-file> is required"
[ -f "$OUT" ] || die "no annotation file at $OUT"

command -v gh >/dev/null 2>&1 || die "gh (GitHub CLI) not found on PATH"
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"

REPO="${REPO:-$(repo_slug)}"
[ -n "$REPO" ] || die "could not determine owner/name; pass --repo"

TMP="$(job_tmp)"
COMMENTS="$TMP/lpr-comments.$$.json"
FILE_NOTES="$TMP/lpr-file-notes.$$.md"
: > "$FILE_NOTES"
printf '[]' > "$COMMENTS"

N_LINE=0 N_FILE=0 N_Q=0
while IFS=$'\t' read -r path start end side kind body; do
    [ -n "$path" ] || continue
    text="$(printf '%b' "$body")"

    if [ "$kind" = question ]; then
        N_Q=$((N_Q + 1))
        continue
    fi

    if [ "$side" = FILE ]; then
        N_FILE=$((N_FILE + 1))
        printf -- '- **`%s`** — %s\n' "$path" "$text" >> "$FILE_NOTES"
        continue
    fi

    # GitHub wants start_line only for a multi-line comment; sending start_line
    # equal to line is rejected, so single-line comments omit it entirely.
    if [ "$start" != "$end" ] && [ "$start" -gt 0 ] 2>/dev/null; then
        jq --arg p "$path" --arg b "$text" --arg s "$side" \
           --argjson sl "$start" --argjson l "$end" \
           '. + [{path:$p, body:$b, side:$s, start_side:$s, start_line:$sl, line:$l}]' \
           "$COMMENTS" > "$COMMENTS.new"
    else
        jq --arg p "$path" --arg b "$text" --arg s "$side" --argjson l "$end" \
           '. + [{path:$p, body:$b, side:$s, line:$l}]' \
           "$COMMENTS" > "$COMMENTS.new"
    fi
    mv "$COMMENTS.new" "$COMMENTS"
    N_LINE=$((N_LINE + 1))
done < <(bash "$HERE/annotations.sh" parse "$OUT")

if [ "$N_LINE" -eq 0 ] && [ "$N_FILE" -eq 0 ]; then
    rm -f "$COMMENTS" "$FILE_NOTES"
    emit POSTED no
    emit LINE_COMMENTS 0
    emit FILE_NOTES 0
    emit QUESTIONS "$N_Q"
    emit REASON "nothing to post (questions and empty annotations don't get posted)"
    exit 0
fi

# Body: whatever the caller passed, plus the file-level notes that have no line
# to attach to. Never empty — a review with a blank body reads as a mistake.
FULL_BODY="${BODY:-Review notes from a local pass over the diff.}"
if [ -s "$FILE_NOTES" ]; then
    FULL_BODY="$FULL_BODY

**File-level notes**

$(cat "$FILE_NOTES")"
fi

# The digest covers FULL_BODY, not the --body argument: the file-level notes are
# folded in here, so approving the caller's framing alone would approve less text
# than the PR would actually receive.
BODY_DIGEST="$(body_digest "$FULL_BODY")"

# commit_id is optional — GitHub defaults to the PR head. Pin it when the caller
# knows the SHA it reviewed, so a push mid-review makes the API reject the stale
# comments instead of silently attaching them to lines that moved.
PAYLOAD="$TMP/lpr-review.$$.json"
jq -n --arg body "$FULL_BODY" --arg commit "$COMMIT" --slurpfile comments "$COMMENTS" \
   '{body:$body, event:"COMMENT", comments:$comments[0]}
    + (if $commit == "" then {} else {commit_id:$commit} end)' \
   > "$PAYLOAD"

if [ "$DRY" = yes ]; then
    cat "$PAYLOAD"
    emit POSTED no
    emit LINE_COMMENTS "$N_LINE"
    emit FILE_NOTES "$N_FILE"
    emit QUESTIONS "$N_Q"
    emit PAYLOAD "$PAYLOAD"
    emit BODY_FILE "$(write_body_file "$FULL_BODY" review-body)"
    emit BODY_DIGEST "$BODY_DIGEST"
    exit 0
fi

# Last gate before the author's inbox: the summary body must be text the user has
# read and approved. Checked after the payload is built so the digest is over the
# bytes that would be sent.
require_body_approval "$FULL_BODY" "$APPROVED" "review summary"

RESP="$(gh api "repos/$REPO/pulls/$PR/reviews" \
    --method POST --input "$PAYLOAD" 2>&1)" || {
    printf '%s\n' "$RESP" >&2
    die "posting the review failed (payload kept at $PAYLOAD)"
}

emit POSTED yes
emit REVIEW_URL "$(printf '%s' "$RESP" | jq -r '.html_url // empty')"
emit LINE_COMMENTS "$N_LINE"
emit FILE_NOTES "$N_FILE"
emit QUESTIONS "$N_Q"
rm -f "$COMMENTS" "$FILE_NOTES"
