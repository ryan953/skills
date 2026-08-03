#!/usr/bin/env bash
# Fetch a GitHub PR's diff and run it through `meat` to produce a reading diff.
# Usage: review.sh <pr-url-or-number> [--repo owner/name]
#
# Prints two JSON objects, newline-separated:
#   1. PR metadata (from `gh pr view`)
#   2. meat's result (smart_diff, summary, elision, token counts)
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: review.sh <pr-url-or-number> [--repo owner/name]" >&2
  exit 2
fi

PR="$1"
shift
REPO_ARGS=()
if [ "${1:-}" = "--repo" ]; then
  REPO_ARGS=(--repo "$2")
fi

command -v gh >/dev/null || { echo "gh (GitHub CLI) not found on PATH" >&2; exit 1; }

MEAT="$(command -v meat || true)"
if [ -z "$MEAT" ]; then
  MEAT="$HOME/go/bin/meat"
  [ -x "$MEAT" ] || { echo "meat not found on PATH or at ~/go/bin/meat — go install meat.dev/cmd/meat@latest" >&2; exit 1; }
fi

# No OpenAI/Anthropic key, but OpenRouter's Anthropic-compatible endpoint is
# configured (ANTHROPIC_BASE_URL + OPENROUTER_API_KEY): this meat build has a
# local patch (~/code/meat) so ANTHROPIC_BASE_URL alone falls back to
# OPENROUTER_API_KEY for the x-api-key header. That path only triggers for a
# Claude model, so default MEAT_MODEL to one unless the user already set it.
if [ -z "${OPENAI_API_KEY:-}" ] && [ -z "${ANTHROPIC_API_KEY:-}" ] \
   && [ -n "${OPENROUTER_API_KEY:-}" ] && [ -n "${ANTHROPIC_BASE_URL:-}" ] \
   && [ -z "${MEAT_MODEL:-}" ]; then
  export MEAT_MODEL="claude-opus-4-8"
fi

gh pr view "$PR" "${REPO_ARGS[@]}" \
  --json title,url,state,author,baseRefName,headRefName,additions,deletions,changedFiles,body

DIFF="$(gh pr diff "$PR" "${REPO_ARGS[@]}")"

if [ -z "$DIFF" ]; then
  echo '{"error":"empty diff — PR may have no changes or gh could not fetch it"}' >&2
  exit 1
fi

printf '%s' "$DIFF" | "$MEAT" -json
