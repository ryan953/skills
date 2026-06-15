---
name: list-open-prs
description: Find your open PRs and report their status — ready to merge, needing review, blocked by review feedback, failing CI, or draft. Presents a concise prioritized summary. Use when asked to "check PRs", "what's ready to merge", "PR status", "list open PRs", "my PRs", or "/me list-open-prs".
---

# List Open PRs

Fetch all open PRs for the current GitHub user, enrich each with CI status, review decision, and dex tracking info, then output a categorized markdown report.

**Requires**: GitHub CLI (`gh`) authenticated, `jq`, and `dex`.

## Usage

Run the companion script:

```bash
bash "$(dirname "$0")/fetch-open-prs.sh"
```


## Output

Print the output of the script directly, **do not** reformat it.

The script outputs markdown with PRs grouped into prioritized buckets:

1. **Ready to Merge** — CI passing, review approved
2. **Changes Requested** — reviewer asked for changes
3. **CI Failing** — one or more checks failed
4. **Draft** — PR is still in draft
5. **Awaiting Review** — CI passing, waiting on reviewers
6. **CI Pending** — checks still running

Each table includes the PR URL, relevant status columns, dex task ID (if tracked), and PR title.

## Notes

- Phantom GitHub status check entries (null status/conclusion) are filtered out to avoid false "pending" classifications.
- Dex tracking tasks are matched by searching task descriptions and context for the PR URL.
