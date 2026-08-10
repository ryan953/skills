---
name: meat-pr-review
description: Abridge a diff down to its "reading diff" with meat (https://github.com/boldsoftware/meat) — the parts actually worth a human's attention (concepts, algorithm choices, architecture), stripping style/nil-check/import trivia. Works against a GitHub PR or a purely local branch/range (including uncommitted and untracked work), so it applies before anything is pushed. Use when asked to "meat review", "abridge this PR", "abridge my branch", "reading diff", or to condense a diff before a full review. Complements (does not replace) deep-pr-review, html-review, or code-review — meat only produces the abridged diff + one-line summary; pair it with those skills for a full findings-based review.
allowed-tools: Bash, Read
---

# meat review (PR or local branch)

Feed a diff through `meat` to get a "reading diff": the model drops everything not
worth reviewing (style, nil-checks, imports, mechanical churn) and keeps concepts,
algorithm choices, and architecture. The diff can come from a GitHub PR **or** from
the local repo — a branch, an explicit range, or the working tree — so an unpushed
branch is reviewable the same way a PR is.

This skill only produces the abridged diff plus a one-line summary — it does not
itself hunt for bugs or leave PR comments. Use `deep-pr-review` / `code-review` /
`html-review` for that, feeding them the abridged diff instead of the raw one to
save their attention for what matters.

## Step 0: verify meat (and gh, for PR mode)

```bash
command -v meat || echo "install: go install meat.dev/cmd/meat@latest"
command -v gh || echo "install: brew install gh"   # only needed for PR mode
```

`meat` needs an LLM key in the environment, but **do not set one up by hand** —
`review.sh` resolves this itself in Step 1, including the OpenRouter-only case
described below, and it fails with an actionable message naming the variables if
there is genuinely nothing to use. Just run the script.

Note when reading the environment yourself that `ANTHROPIC_API_KEY` is commonly
exported *empty* in a Claude Code session, so "is the variable present" is the
wrong question — anything checking credentials must treat set-but-empty as unset
(`${VAR:-}`, not `${VAR+}` / `[ -v VAR ]`). Never guess or fabricate a key, and
never echo a key or any prefix of one.

`meat` also accepts `-model` and `$MEAT_MODEL` to pick a specific model; otherwise
it uses its built-in OpenAI-based default.

**OpenRouter routing (this install is patched for it):** when
`OPENROUTER_API_KEY` is the only usable key, `review.sh` exports — for its own
process only — `ANTHROPIC_BASE_URL=https://openrouter.ai/api` and
`MEAT_MODEL=claude-opus-4-8`. Both are needed: meat falls back to
`OPENROUTER_API_KEY` for the `x-api-key` header when `ANTHROPIC_BASE_URL` is set
with no `ANTHROPIC_API_KEY` (OpenRouter's Anthropic-compatible endpoint accepts
an OpenRouter key the same way), and that code path only runs at all for a Claude
model name — without one meat takes the OpenAI path and neither variable applies.

Both are fallbacks, not overrides: a real `ANTHROPIC_API_KEY`, an `OPENAI_API_KEY`,
or a caller-set `ANTHROPIC_BASE_URL` / `MEAT_MODEL` / `--model` all still win.

The `x-api-key` fallback is a local patch (not upstream boldsoftware/meat) — the
source lives at `~/code/meat` (`meat/anthropic.go`, `NewAnthropicFromEnv`);
rebuild with `go build -o ~/go/bin/meat ./cmd/meat` after any
`go install .../meat@latest` overwrites the binary.

## Step 1: run the review script

```bash
"$HOME/code/skills/skills/meat-pr-review/scripts/review.sh" [target] [flags]
```

Run it from inside the checkout (local mode needs the repo; PR mode doesn't, given
`--repo`). Pick the target by what you were asked to review:

| Target | What it reviews |
|---|---|
| *(none)* | the PR for the current branch if there is one, else the local branch diff |
| `121125` or a `.../pull/121125` URL | that PR |
| `feat/thing` | that branch's PR if it has one, else that branch vs its fork point |
| `main..HEAD`, `origin/main...feat/x` | exactly that git range |
| `--local` | forces local mode even when a PR exists — review what's on disk, not what's pushed |
| `--pr <n> [--repo owner/name]` | forces PR mode |

Local mode defaults to the whole branch **including uncommitted and untracked
work**, matching the `/diff` skill's fork-point detection (it reuses
`diff/scripts/detect-range.sh`, so a stale local `main` doesn't drag in upstream
commits). Untracked files are staged into a *copy* of the index — the real index is
never touched. Narrow it with:

- `--base <ref>` — diff against this ref instead of the detected fork point
- `--committed` — commits only, ignore the working tree
- `--no-untracked` — skip files git doesn't know about yet

Other flags: `--model <name>` and `--no-cache` pass through to `meat`.

The script prints two JSON objects, newline-separated:

1. **Target metadata** — `kind` is `"pr"` or `"local"`. Both fill `title`, `url`,
   `state`, `author`, `baseRefName`, `headRefName`, `range`, `additions`,
   `deletions`, `changedFiles`, `body`. PR mode takes them from `gh pr view`; local
   mode fills them from git (`body` is the commit log, `state` is `LOCAL`, `url` is
   empty, plus `repo` and `dirty`).
2. **meat's result** (from `meat -json`) — `smart_diff` (the abridged reading diff),
   `summary` (one line), `elision` (a `kept N/M changed lines` manifest line),
   `input_tokens`, `output_tokens`.

`meat` caches by the SHA of (model + rubric + diff contents) under `~/.meat`, so
re-running on an unchanged diff is instant and needs no credentials on a cache hit.
A local diff changes every time the working tree does, so expect misses while
editing — that is the cache working, not failing.

## Step 2: present the result

Show the user, in this order:

1. What was reviewed: PR title + link + author, or (local) the branch and range,
   plus file/line-change stats. Say which mode ran — reviewing the working tree and
   reviewing the PR are different claims about what the code currently is.
2. meat's one-line `summary`.
3. The `smart_diff` (the abridged reading diff) — this is what they should actually
   read, not the raw diff.
4. If `elision` shows most lines were kept (e.g. `kept 240/271`), note that the diff
   is mostly substantive and a full review may be warranted anyway; if it shows most
   were dropped (e.g. `kept 12/271`), highlight that most of it was mechanical.

## Step 3 (optional): hand off to a full review

If the user wants an actual list of findings (bugs, style issues, alternatives), do
not stop at the abridged diff — invoke `deep-pr-review`, `code-review`, or
`html-review` and point them at the PR or branch, mentioning that the meat
summary/reading diff already scoped which hunks matter most.

## Notes

- `smart_diff` preserves unified-diff shape for navigation/coloring but is **not** an
  applicable patch — removed lines can leave hunk headers stale. Don't try to `git
  apply` it.
- Very large diffs are split at file/hunk boundaries and abridged chunk-by-chunk,
  then merged — expect longer runtimes on big diffs, not failures.
- On a trunk branch with nothing to compare, local mode falls back to the working
  tree vs `HEAD`, or to `HEAD~1..HEAD` when clean — the same rule `/diff` uses.
- `scripts/target.sh` holds the pure target-classification logic (PR number vs URL
  vs range vs branch, and which mode wins); `scripts/target.test.sh` covers it with
  no network or repo. Run that test after touching either.
