#!/usr/bin/env bash
set -euo pipefail

# Fetch all open PRs authored by the current user, enrich with detailed status
# from GitHub, match against dex tracking tasks, and output categorized markdown tables.

LIMIT="${1:-100}"
TMPDIR_LOCAL=$(mktemp -d)
trap 'rm -rf "$TMPDIR_LOCAL"' EXIT

# --- Step 1: Fetch open PRs ---
gh search prs --author=@me --state=open --limit "$LIMIT" \
  --json number,title,url,repository > "$TMPDIR_LOCAL/prs.json"

pr_count=$(jq 'length' < "$TMPDIR_LOCAL/prs.json")
if [ "$pr_count" -eq 0 ]; then
  echo "No open PRs found."
  exit 0
fi

# --- Step 2: Fetch detailed status for each PR (as JSONL) ---
: > "$TMPDIR_LOCAL/details.jsonl"
while IFS= read -r url; do
  gh pr view "$url" \
    --json number,title,state,url,isDraft,mergeable,reviewDecision,createdAt,statusCheckRollup \
    >> "$TMPDIR_LOCAL/details.jsonl" 2>/dev/null || echo '{}' >> "$TMPDIR_LOCAL/details.jsonl"
done < <(jq -r '.[].url' < "$TMPDIR_LOCAL/prs.json")

# --- Step 3: Fetch dex tracking tasks ---
dex list "Track PR:" --json > "$TMPDIR_LOCAL/dex.json" 2>/dev/null || echo '[]' > "$TMPDIR_LOCAL/dex.json"

# --- Step 4: Merge and categorize ---
jq -n '
  [inputs] | . as $all |
  ($all | last) as $dex |
  ($all | .[:-1]) as $prs |

  def ci_status:
    [(.statusCheckRollup // [])[] | select(.status != null)] as $checks |
    if ($checks | length) == 0 then "pending"
    elif [$checks[] | select(.conclusion == "FAILURE" or .conclusion == "CANCELLED" or .conclusion == "TIMED_OUT")] | length > 0 then "failing"
    elif [$checks[] | select(.status != "COMPLETED")] | length > 0 then "pending"
    else "passing"
    end;

  def failed_checks:
    [(.statusCheckRollup // [])[] | select(.status != null) | select(.conclusion == "FAILURE" or .conclusion == "CANCELLED" or .conclusion == "TIMED_OUT") | .name] | join(", ");

  def pending_checks:
    [(.statusCheckRollup // [])[] | select(.status != null) | select(.status != "COMPLETED") | .name] | join(", ");

  def find_dex($url; $dex_tasks):
    [$dex_tasks[] | select((.context // "") + " " + (.description // "") | test($url; "i"))] |
    if length > 0 then .[0].id else "—" end;

  def categorize:
    ci_status as $ci |
    if .state != "OPEN" and .state != null then
      if .state == "MERGED" then "merged" else "closed" end
    elif .isDraft == true then "draft"
    elif $ci == "passing" and .reviewDecision == "APPROVED" then "ready"
    elif .reviewDecision == "CHANGES_REQUESTED" then "changes_requested"
    elif $ci == "failing" then "ci_failing"
    elif .reviewDecision == "REVIEW_REQUIRED" and $ci == "passing" then "awaiting_review"
    elif $ci == "pending" then "ci_pending"
    else "awaiting_review"
    end;

  [ $prs[] | select(.url != null) |
    {
      bucket: categorize,
      title: .title,
      url: .url,
      mergeable: (.mergeable // "UNKNOWN"),
      review: (.reviewDecision // "NONE"),
      ci: ci_status,
      failed_checks: failed_checks,
      pending_checks: pending_checks,
      created: ((.createdAt // "") | if . == "" then "unknown"
        else
          (now - (. | fromdateiso8601)) as $secs |
          ($secs / 86400 | floor) as $days |
          if $days < 1 then
            (($secs / 3600 | floor) as $hrs |
             if $hrs < 1 then "\($secs / 60 | floor | . + 0.5 | floor)m ago"
             else "\($hrs)h ago" end)
          elif $days < 30 then "\($days)d ago"
          else (. | split("T")[0])
          end
        end),
      dex_task: find_dex(.url; $dex)
    }
  ]
' "$TMPDIR_LOCAL/details.jsonl" "$TMPDIR_LOCAL/dex.json" > "$TMPDIR_LOCAL/merged.json"

# --- Step 5: Render markdown ---
render_table() {
  local bucket="$1"
  local heading="$2"

  local rows
  rows=$(jq -r --arg b "$bucket" '[.[] | select(.bucket == $b)] | length' < "$TMPDIR_LOCAL/merged.json")
  [ "$rows" -eq 0 ] && return

  echo ""
  echo "## $heading"
  echo ""

  case "$bucket" in
    ready)
      echo "| URL | Mergeable | Dex Task | PR |"
      echo "|-----|-----------|----------|----|"
      jq -r --arg b "$bucket" '
        .[] | select(.bucket == $b) |
        "| \(.url) | \(.mergeable) | \(.dex_task) | \(.title) |"' < "$TMPDIR_LOCAL/merged.json"
      ;;
    changes_requested)
      echo "| URL | Review | Dex Task | PR |"
      echo "|-----|--------|----------|----|"
      jq -r --arg b "$bucket" '
        .[] | select(.bucket == $b) |
        "| \(.url) | \(.review) | \(.dex_task) | \(.title) |"' < "$TMPDIR_LOCAL/merged.json"
      ;;
    ci_failing)
      echo "| URL | Failed Checks | Dex Task | PR |"
      echo "|-----|---------------|----------|----|"
      jq -r --arg b "$bucket" '
        .[] | select(.bucket == $b) |
        "| \(.url) | \(.failed_checks) | \(.dex_task) | \(.title) |"' < "$TMPDIR_LOCAL/merged.json"
      ;;
    draft)
      echo "| URL | Created | Dex Task | PR |"
      echo "|-----|---------|----------|----|"
      jq -r --arg b "$bucket" '
        .[] | select(.bucket == $b) |
        "| \(.url) | \(.created) | \(.dex_task) | \(.title) |"' < "$TMPDIR_LOCAL/merged.json"
      ;;
    awaiting_review)
      echo "| URL | Created | Dex Task | PR |"
      echo "|-----|---------|----------|----|"
      jq -r --arg b "$bucket" '
        .[] | select(.bucket == $b) |
        "| \(.url) | \(.created) | \(.dex_task) | \(.title) |"' < "$TMPDIR_LOCAL/merged.json"
      ;;
    ci_pending)
      echo "| URL | Running Checks | Dex Task | PR |"
      echo "|-----|----------------|----------|----|"
      jq -r --arg b "$bucket" '
        .[] | select(.bucket == $b) |
        "| \(.url) | \(.pending_checks) | \(.dex_task) | \(.title) |"' < "$TMPDIR_LOCAL/merged.json"
      ;;
    merged|closed)
      jq -r --arg b "$bucket" '
        .[] | select(.bucket == $b) |
        "- \(.title) (\($b))"' < "$TMPDIR_LOCAL/merged.json"
      ;;
  esac
}

echo "# Open PRs"
echo ""
echo "_${pr_count} PRs found_"

render_table "ready"              "Ready to Merge"
render_table "changes_requested"  "Changes Requested"
render_table "ci_failing"         "CI Failing"
render_table "draft"              "Draft"
render_table "awaiting_review"    "Awaiting Review"
render_table "ci_pending"         "CI Pending"
render_table "merged"             "Cleaned Up"
render_table "closed"             "Cleaned Up"
