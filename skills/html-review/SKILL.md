---
name: html-review
description: Review a pull request by generating a self-contained HTML artifact and embedding it in the PR description for live preview. Renders logical changes (not raw diff) with severity-coded findings, moved-line side-by-side views, deep-links back to the PR, a light/dark toggle, and a testing-notes plan. Use whenever opening or updating a PR, when asked to "review this PR", "html review", "html-review", "preview this PR", "add a PR preview", "explain this PR visually", or "make a review artifact".
---

# HTML PR Review

Produce an HTML artifact that explains a pull request, then embed it (hidden) in the PR
description so it can be rendered live by the preview app at
`https://insecure-html-azure.vercel.app`.

This skill both **produces** the review content and **formats + installs** it into the PR.
It is idempotent: re-running on an existing PR replaces the previous preview block in place
rather than appending a duplicate.

## Step 1: Resolve the PR

```bash
gh pr view --json url,number,title,headRefName,baseRefName,body
```

If there is no PR for the current branch yet, create the PR first (drafts are fine), then
re-read it. Capture:

- `PR_URL` — the full `https://github.com/<owner>/<repo>/pull/<n>` URL
- `PR_NUMBER`, `PR_TITLE`, `BASE`/`HEAD` refs, and the existing `body`

## Step 2: Get the diff and identify logical changes

```bash
BASE=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || echo main)
git diff "$BASE"...HEAD
```

Do **not** transcribe the diff. Instead extract the **logical changes** — the smallest
meaningful units of intent, even when one change is split across several hunks or files.
For each, classify it as one of: **added**, **removed**, **replaced**, or **moved**.

- Explain the logical change **first** (what changed and why it matters); reference the code
  **second**, only when it clarifies.
- Smaller, well-scoped units are better than large ones. Split aggressively.
- For lines that merely **moved** (content unchanged, location changed), do not treat them as
  edits — flag them as moves and present them side-by-side (old location → new location).
- Assign each finding a **severity**: `critical`, `high`, `medium`, `low`, or `info`.

## Step 3: Build the HTML artifact

Start from `template.html` in this skill directory and fill in the placeholders. The artifact
must include, in order:

1. **Header** — the PR title, linked to `PR_URL`.
2. **Light/dark toggle** — defaults to the viewer's `prefers-color-scheme`.
3. **Severity legend.**
4. **Logical changes** — one card per change, severity-coded, description first. Whenever a
   card cites a specific file/line/hunk, link it back to the real PR for click-through
   verification, using a GitHub deep link: a line permalink
   `https://github.com/<owner>/<repo>/blob/<HEAD_SHA>/<path>#L<start>-L<end>`, or the PR
   files tab `${PR_URL}/files`. (Get `<HEAD_SHA>` from `git rev-parse HEAD`.)
5. **Moved lines** — a side-by-side block for any moved-but-unchanged content.
6. **Testing notes** — a step-by-step test plan: an example URL (or URL format), exactly what
   to click, what is expected, and what the behavior **used to be**.

### Hard formatting rules for the embedded HTML

The preview app extracts the HTML from inside one HTML comment, so it must be a single clean
block:

- **No blank lines** anywhere in the artifact.
- **No HTML comments** (`<!-- ... -->`) anywhere inside the artifact — strip every comment,
  including any left over from `template.html`.
- Self-contained: inline all CSS and JS. No external scripts. Assume it runs in a sandboxed
  iframe with no network access.

## Step 4: Install it in the PR description

The artifact is embedded **hidden inside an HTML comment** so it does not clutter the rendered
PR description on GitHub. Above it, add a **visible** link to the live preview.

The block written into the PR body must match this exact shape (the markers are matched by a
regex in the preview app — `html-preview:start` sits on the same line as `<!--`, and
`html-preview:end -->` is on its own line):

```
[▶ Open live HTML preview](https://insecure-html-azure.vercel.app/?pr-url=PR_URL)

<!-- html-preview:start
…the artifact HTML on its own lines, no blank lines, no comments…
html-preview:end -->
```

Replace `PR_URL` with the real URL.

**Idempotent update:** if the existing body already contains a `<!-- html-preview:start … html-preview:end -->`
block (and/or the preview link line), remove the old link line and the entire old block
first, then append the freshly generated link + block. Preserve all other PR description
content. Update the PR with:

```bash
gh pr edit <PR_NUMBER> --body-file <file>
```

Write the new body to a temp file (not an inline arg) to avoid shell-escaping issues with the HTML.

## Step 5: Confirm

Report the `PR_URL`, the number of logical changes and moved blocks rendered, and the live
preview link (`https://insecure-html-azure.vercel.app/?pr-url=<PR_URL>`). Do not paste the raw
HTML back to the user.

## The preview contract

The renderer (`ryan953/insecure-html`, deployed at `insecure-html-azure.vercel.app`) fetches the
PR via the GitHub API and extracts every section matching:

```
/<!--\s*html-preview:start\s*\r?\n([\s\S]*?)\r?\n\s*html-preview:end\s*-->/g
```

It renders each captured section in a sandboxed iframe. Multiple preview blocks in one PR body
are rendered as separate sections, so keep to a single block unless you intend several.
