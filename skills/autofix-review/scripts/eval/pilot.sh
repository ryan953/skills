#!/usr/bin/env bash
# pilot.sh — the whole evaluation in one call, with a log you can hand back.
#
# Runs collect -> slice -> label -> run -> score, tees everything to
# <outdir>/pilot.log, and prints a summary short enough to paste.
#
# Usage:
#   pilot.sh [--repo owner/name] [--arm seer|both|all] [--decider <login>]
#            [--repo-path ~/code/sentry] [--limit 100] [--since 2025-06-01]
#            [--out <dir>] [--read-only]
#
# Defaults are the seer arm against getsentry/sentry, which is where the signal
# is: the chain exists by construction and the merge-or-close IS the verdict.
#
# Needs `gh` authenticated and a clone to run probes against. Without
# --read-only the probe wave runs, which is the point of running this locally
# rather than in a sandbox.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REPO=getsentry/sentry; ARM=seer; DECIDER=""; REPO_PATH="$HOME/code/sentry"
LIMIT=100; SINCE=2025-06-01; OUT="./autofix-review-pilot"; RO=""
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) REPO="$2"; shift 2 ;;
        --arm) ARM="$2"; shift 2 ;;
        --decider) DECIDER="$2"; shift 2 ;;
        --repo-path) REPO_PATH="$2"; shift 2 ;;
        --limit) LIMIT="$2"; shift 2 ;;
        --since) SINCE="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --read-only) RO=--read-only; shift ;;
        *) printf 'unknown flag: %s\n' "$1" >&2; exit 1 ;;
    esac
done

mkdir -p "$OUT" || exit 1
LOG="$OUT/pilot.log"
: > "$LOG"
say() { printf '%s\n' "$*" | tee -a "$LOG"; }

# Fail loudly and early rather than producing an empty sample quietly — an empty
# sample is this harness's characteristic failure and it looks like success.
command -v gh >/dev/null 2>&1 || { say "FATAL: gh not on PATH"; exit 1; }
gh auth status >>"$LOG" 2>&1 || { say "FATAL: gh not authenticated (gh auth status)"; exit 1; }
[ -d "$REPO_PATH/.git" ] || { say "FATAL: no git clone at $REPO_PATH (pass --repo-path)"; exit 1; }

say "repo=$REPO arm=$ARM decider=${DECIDER:-<anyone>} clone=$REPO_PATH probes=$([ -n "$RO" ] && echo off || echo on)"
say "started $(date -u +%Y-%m-%dT%H:%M:%SZ)"
say ""

cd "$REPO_PATH" || exit 1
step() { say "--- $1 ---"; }

step collect
"$HERE/collect.sh" --repo "$REPO" --arm "$ARM" ${DECIDER:+--decider "$DECIDER"} \
    --limit "$LIMIT" --since "$SINCE" --out "$OUT/raw.jsonl" 2>>"$LOG"
say "candidates: $(wc -l < "$OUT/raw.jsonl" | tr -d ' ')"
[ -s "$OUT/raw.jsonl" ] || { say "FATAL: no candidates. Widen --since, raise --limit, or drop --decider."; exit 1; }

step slice
"$HERE/slice.sh" --repo "$REPO" --from "$OUT/raw.jsonl" --out "$OUT/sliced.jsonl" 2>>"$LOG"
say "sliced: $(wc -l < "$OUT/sliced.jsonl" | tr -d ' ')"

step label
"$HERE/label.sh" "$OUT/sliced.jsonl" > "$OUT/labelled.jsonl" 2>>"$LOG"
say "labels:"
jq -r '.label' "$OUT/labelled.jsonl" | sort | uniq -c | sed 's/^/  /' | tee -a "$LOG"
say ""
say "per case (read this before trusting any number below):"
jq -r '["  " + (.pr|tostring), .state, .label, .label_why] | @tsv' "$OUT/labelled.jsonl" | tee -a "$LOG"
say ""

SCOREABLE="$(jq -r 'select(.label == "ACCEPT_TRUTH" or .label == "REJECT_TRUTH") | .pr' "$OUT/labelled.jsonl" 2>/dev/null | wc -l | tr -d ' ')"
[ "$SCOREABLE" -gt 0 ] || { say "FATAL: nothing scoreable after labelling."; exit 1; }

step run
"$HERE/run.sh" --cases "$OUT/labelled.jsonl" --repo-path "$REPO_PATH" $RO \
    --out "$OUT/predictions.jsonl" 2>>"$LOG"
PREDS="$(wc -l < "$OUT/predictions.jsonl" 2>/dev/null | tr -d ' ')"
say "predictions: ${PREDS:-0} (of $SCOREABLE scoreable)"
# An empty predictions file is this harness's characteristic failure and it
# looks exactly like a legitimately empty sample by the time score.sh sees it.
# Refuse to print a confusion matrix over nothing.
if [ "${PREDS:-0}" -eq 0 ]; then
    say "FATAL: every case failed to run. The last few reasons:"
    grep -iE 'gather failed|not in the clone|could not create|no .claude. on PATH' "$LOG" | tail -5 | sed 's/^/  /' | tee -a "$LOG"
    exit 1
fi

step score
"$HERE/score.sh" --predictions "$OUT/predictions.jsonl" --by-arm --reasons "$OUT/reasons.tsv" 2>&1 | tee -a "$LOG"

say ""
say "=== paste everything from 'repo=' down, or hand over $LOG ==="
say "reasons for the true rejects: $OUT/reasons.tsv"
