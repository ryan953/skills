#!/usr/bin/env bash
# slice.sh — reconstruct, for each collected PR, the state a reviewer first saw.
#
# This is the part that makes the evaluation honest. The skill must judge the
# commits that existed *before* the first human review, blind to the review
# itself; scoring it against the final merged tree would be scoring it against
# an answer key it was allowed to read.
#
# Usage:
#   collect.sh ... | slice.sh --repo owner/name [--out cases.jsonl]
#   slice.sh --from cases.raw.jsonl --repo owner/name
#
# Needs `gh` for the two things `gh pr view` does not return: inline review
# comments (which carry the file path) and per-commit file lists.

set -euo pipefail

REPO=""; FROM="-"; OUT="-"; NO_FILES=""
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) REPO="$2"; shift 2 ;;
        --from) FROM="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --no-files) NO_FILES=1; shift ;;
        *) printf 'unknown flag: %s\n' "$1" >&2; exit 1 ;;
    esac
done
command -v gh >/dev/null 2>&1 || { printf 'gh (GitHub CLI) not found on PATH\n' >&2; exit 1; }

# Reviews and comments from these do not start the clock: a lint bot posting
# three seconds after push would make every PR look reviewed before its own
# commits landed, and the pre-review slice would collapse to nothing.
BOTS_RE='\[bot\]$|^codecov|^sentry-io|^getsentry-bot|^seer-by-sentry|^github-actions'

slice_one() {
    # Two `local`s, not one: every word on a `local` line is expanded before any
    # of its assignments take effect, so `$raw` would still be unset here and the
    # fallback would parse an empty string into an empty repo.
    local raw="$1"
    local repo="${REPO:-$(printf '%s' "$raw" | jq -r '.repo // ""')}"
    local number author state
    number="$(printf '%s' "$raw" | jq -r '.number')"
    author="$(printf '%s' "$raw" | jq -r '.author.login // ""')"
    state="$(printf '%s' "$raw" | jq -r '.state')"

    # Inline review comments carry the path; issue comments do not. Both count
    # as "a human looked", but only the inline ones can be joined to a file.
    local inline
    inline="$(gh api "repos/$repo/pulls/$number/comments" --paginate 2>/dev/null \
        | jq -s 'add // []' 2>/dev/null || echo '[]')"

    local first_review
    first_review="$(printf '%s' "$raw" | jq -r --arg a "$author" --arg bots "$BOTS_RE" --argjson inline "$inline" '
        [ ((.reviews // [])[]  | select((.author.login // "") != $a)
                               | select(((.author.login // "") | test($bots)) | not)
                               | .submittedAt),
          ((.comments // [])[] | select((.author.login // "") != $a)
                               | select(((.author.login // "") | test($bots)) | not)
                               | .createdAt),
          ($inline[]           | select((.user.login // "") != $a)
                               | select(((.user.login // "") | test($bots)) | not)
                               | .created_at) ]
        | map(select(. != null)) | sort | (.[0] // "")')"

    local arm; arm="$(printf '%s' "$raw" | jq -r '.arm // ""')"
    if [ -z "$first_review" ]; then
        # On the merged/closed arms there is no "state a reviewer first saw", so
        # there is nothing to score and the case is dropped.
        #
        # The seer arm is different and must not be dropped: a bot opened the PR
        # complete, and the decision being scored is the merge or the close, not
        # a review. Most autofix PRs carry no review at all, so requiring one
        # here would silently return an empty sample — which is exactly what it
        # did the first time.
        if [ "$arm" != seer ]; then
            printf 'pr %s: no human review, skipped\n' "$number" >&2; return 0
        fi
        first_review="$(printf '%s' "$raw" | jq -r '.mergedAt // .closedAt // ""')"
        [ -n "$first_review" ] || { printf 'pr %s: no decision timestamp, skipped\n' "$number" >&2; return 0; }
    fi

    local pre post head_at_review post_n
    pre="$(printf '%s' "$raw" | jq -c --arg t "$first_review" \
        '[ (.commits // [])[] | select(.committedDate < $t) ]')"
    post="$(printf '%s' "$raw" | jq -c --arg t "$first_review" \
        '[ (.commits // [])[] | select(.committedDate >= $t) ]')"
    head_at_review="$(printf '%s' "$pre" | jq -r '(.[-1].oid) // ""')"
    # Merges of the base branch are not a response to review, so they must not
    # make an untouched PR look like one that was revised.
    post_n="$(printf '%s' "$post" | jq '[ .[] | select((.messageHeadline // "") | test("^Merge (branch|remote|pull)") | not) ] | length')"

    if [ -z "$head_at_review" ]; then
        head_at_review="$(printf '%s' "$raw" | jq -r '.headRefOid // ""')"
        [ -n "$head_at_review" ] || { printf 'pr %s: no commits before the decision, skipped\n' "$number" >&2; return 0; }
    fi

    # Which files did the post-review commits touch? Needed for the
    # comment-then-change join; one API call per commit, so it is skippable.
    local post_files='[]'
    if [ -z "$NO_FILES" ]; then
        post_files="$(printf '%s' "$post" | jq -r '.[].oid' | while read -r sha; do
            [ -n "$sha" ] || continue
            gh api "repos/$repo/commits/$sha" --jq '[.files[]?.filename]' 2>/dev/null || echo '[]'
        done | jq -s 'add // [] | unique')"
    fi

    local comment_paths
    comment_paths="$(printf '%s' "$inline" | jq -c --arg a "$author" --arg bots "$BOTS_RE" '
        [ .[] | select((.user.login // "") != $a)
              | select(((.user.login // "") | test($bots)) | not)
              | .path ] | unique')"

    # Closing comments: what was said from the start of the day BEFORE the close
    # onwards. Anchoring at midnight of the close day itself -- which is what
    # `.[0:10] + "T00:00:00Z"` did -- drops a reason given the previous evening,
    # and the case then reads as an unexplained close and is EXCLUDED.
    local close_comments='[]'
    if [ "$state" = CLOSED ]; then
        local window
        window="$(date -u -d "$(printf '%s' "$raw" | jq -r '.closedAt // ""') -1 day" +%Y-%m-%dT00:00:00Z 2>/dev/null \
                  || printf '')"
        close_comments="$(printf '%s' "$raw" | jq -c --arg bots "$BOTS_RE" --arg window "$window" '
            (.closedAt // "") as $c
            | [ (.comments // [])[]
                | select(((.author.login // "") | test($bots)) | not)
                | select($c == "" or (.createdAt >= $window))
                | {author: (.author.login // ""), body: (.body // "")} ]')"
    fi

    # The supersession check needs two things nothing was providing: the issue
    # this PR claims to fix, and the commits that landed after it. Without them
    # `superseded_later` was dead outside its unit test -- and it is the check
    # that stops a merged-then-re-fixed PR being scored as a correct accept.
    local issue later
    issue="$(printf '%s' "$raw" | jq -r '(.body // "") | capture("(?<i>[A-Z][A-Z0-9]{2,}-[A-Z0-9]{3,})").i // ""' 2>/dev/null || true)"
    later=""
    if [ -n "$issue" ] && git rev-parse --git-dir >/dev/null 2>&1; then
        later="$(git log --format='%s%n%b' "$head_at_review"..HEAD 2>/dev/null | head -c 200000 || true)"
    fi

    jq -n --argjson raw "$raw" --arg t "$first_review" --arg head "$head_at_review" \
          --argjson pre "$pre" --argjson postn "$post_n" --argjson pf "$post_files" \
          --argjson cp "$comment_paths" --argjson cc "$close_comments" --arg repo "$repo" \
          --arg issue "$issue" --arg later "$later" '{
        repo: $repo, pr: $raw.number, arm: $raw.arm, title: $raw.title, url: $raw.url,
        state: $raw.state, author: ($raw.author.login // ""),
        base_ref: $raw.baseRefName, head_ref: $raw.headRefName,
        review_decision: ($raw.reviewDecision // ""),
        decided_by: ($raw.decided_by // ""),
        issue_id: $issue,
        later_commits_text: $later,
        first_review_at: $t,
        head_sha_at_review: $head,
        pre_review_commits: ($pre | length),
        post_review_commits: $postn,
        review_comment_paths: $cp,
        post_review_files: $pf,
        close_comments: $cc,
        body: ($raw.body // "")
    }'
}

{
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        slice_one "$line" | jq -c .
    done < <([ "$FROM" = - ] && cat || cat "$FROM")
} > >([ "$OUT" = - ] && cat || cat > "$OUT")
wait
