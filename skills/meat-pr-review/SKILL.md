---
name: meat-pr-review
description: Review a GitHub pull request using meat (https://github.com/boldsoftware/meat) to abridge the diff down to its "reading diff" — the parts actually worth a human's attention (concepts, algorithm choices, architecture) — stripping style/nil-check/import trivia. Use when asked to "review this PR with meat", "meat review", "abridge this PR", or to get a condensed/reading diff of a GitHub pull request before doing a full review. Complements (does not replace) deep-pr-review, html-review, or code-review — meat only produces the abridged diff + one-line summary; pair it with those skills for a full findings-based review.
allowed-tools: Bash, Read
---

# meat PR review

Fetch a GitHub PR's diff and run it through `meat` to get a "reading diff": the
model drops everything not worth reviewing (style, nil-checks, imports, mechanical
churn) and keeps concepts, algorithm choices, and architecture. This skill only
produces that abridged diff plus a one-line summary — it does not itself hunt for
bugs or leave PR comments. Use `deep-pr-review` / `code-review` / `html-review` for
that, feeding them the abridged diff instead of the raw one to save their attention
for what matters.

## Step 0: verify meat and gh

```bash
command -v meat || echo "install: go install meat.dev/cmd/meat@latest"
command -v gh || echo "install: brew install gh"
```

`meat` needs an LLM key in the environment — check before running:

```bash
echo "ANTHROPIC_API_KEY: ${ANTHROPIC_API_KEY:+set}"
echo "OPENAI_API_KEY: ${OPENAI_API_KEY:+set}"
echo "OPENROUTER_API_KEY + ANTHROPIC_BASE_URL: ${OPENROUTER_API_KEY:+set}/${ANTHROPIC_BASE_URL:+set}"
```

If none of those are set, tell the user and stop — do not guess or fabricate a key.
`meat` also accepts `-model` and `$MEAT_MODEL` to pick a specific model; otherwise
it uses its built-in OpenAI-based default.

**OpenRouter routing (this install is patched for it):** if only
`ANTHROPIC_BASE_URL` is set (e.g. `https://openrouter.ai/api`, no
`ANTHROPIC_API_KEY`), meat falls back to `OPENROUTER_API_KEY` for the
`x-api-key` header — OpenRouter's Anthropic-compatible endpoint accepts an
OpenRouter key the same way. This requires `$MEAT_MODEL` (or `-model`) to name
a Claude model, e.g.:

```bash
export MEAT_MODEL=claude-opus-4-8
```

Without a Claude model name, meat takes the OpenAI code path by default and
`OPENROUTER_API_KEY`/`ANTHROPIC_BASE_URL` won't apply. This fallback is a local
patch (not upstream boldsoftware/meat) — the source lives at
`~/code/meat` (`meat/anthropic.go`, `NewAnthropicFromEnv`); rebuild with
`go build -o ~/go/bin/meat ./cmd/meat` after any `go install .../meat@latest`
overwrites the binary.

## Step 1: run the review script

```bash
"$HOME/code/skills/skills/meat-pr-review/scripts/review.sh" <pr-url-or-number> [--repo owner/name]
```

Accepts a full PR URL (e.g. `https://github.com/getsentry/sentry/pull/121125`) or a
bare number plus `--repo owner/name` when run from outside that repo's checkout.

The script prints two JSON objects, newline-separated:

1. **PR metadata** — `title`, `url`, `state`, `author`, `baseRefName`, `headRefName`,
   `additions`, `deletions`, `changedFiles`, `body` (from `gh pr view`).
2. **meat's result** (from `meat -json`) — `smart_diff` (the abridged reading diff),
   `summary` (one line), `elision` (a `kept N/M changed lines` manifest line),
   `input_tokens`, `output_tokens`.

`meat` caches by the SHA of (model + rubric + diff contents) under `~/.meat`, so
re-running on an unchanged PR is instant and needs no credentials on a cache hit.

## Step 2: present the result

Show the user, in this order:

1. PR title + link + author + file/line-change stats.
2. meat's one-line `summary`.
3. The `smart_diff` (the abridged reading diff) — this is what they should actually
   read, not the raw `gh pr diff` output.
4. If `elision` shows most lines were kept (e.g. `kept 240/271`), note that the PR
   is mostly substantive and a full review may be warranted anyway; if it shows most
   were dropped (e.g. `kept 12/271`), highlight that most of the diff was mechanical.

## Step 3 (optional): hand off to a full review

If the user wants an actual list of findings (bugs, style issues, alternatives), do
not stop at the abridged diff — invoke `deep-pr-review`, `code-review`, or
`html-review` and point them at the PR, mentioning that the meat summary/reading
diff already scoped which hunks matter most.

## Notes

- `smart_diff` preserves unified-diff shape for navigation/coloring but is **not** an
  applicable patch — removed lines can leave hunk headers stale. Don't try to `git
  apply` it.
- Very large diffs are split at file/hunk boundaries and abridged chunk-by-chunk,
  then merged — expect longer runtimes on big PRs, not failures.
- `-no-cache` (pass through the script if ever needed) forces recompute; not needed
  for normal use.
