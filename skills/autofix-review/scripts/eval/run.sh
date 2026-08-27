#!/usr/bin/env bash
# run.sh — run autofix-review over each labelled case at its pre-review commit.
#
# Two modes, because the two places this runs have different capabilities:
#
#   --print-briefs   emit one dispatch brief per case and stop. For an
#                    orchestrator that will fan the cases out itself (an agent
#                    session with no `claude` binary on PATH).
#   default          drive `claude -p` per case, locally, where the repo clone,
#                    the toolchain and the Sentry MCP all exist.
#
# Either way the prediction is read back from verdict-rule.sh, not from anything
# the model says in prose: the verdict is whatever the deterministic rule makes
# of the artifacts the waves produced, so a model that writes a confident summary
# it did not earn cannot smuggle that into the score.
#
# Usage:
#   run.sh --cases labelled.jsonl --repo-path ~/code/sentry [--out predictions.jsonl]
#          [--read-only] [--print-briefs] [--work-root <dir>] [--max-cases N]
#          [--jobs N]
#
# Cases are independent, so they run --jobs at a time. Serially, twenty cases is
# twenty full four-wave reviews back to back, each with its own worktree and test
# run: hours. The skill fans its own subagents out in parallel; there was no
# reason the harness driving it did not.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"          # .../scripts/eval
# Two levels, not one: $HERE is scripts/eval, so `$HERE/..` is scripts/ and
# every path built from it came out as scripts/scripts/... . Nothing caught it
# because the failure is a stderr line per case and an empty predictions file,
# which score.sh then reports as "no scored cases" -- indistinguishable from a
# sample that legitimately had nothing in it.
SKILL_DIR="$(cd "$HERE/../.." && pwd)"

CASES=""; REPO_PATH=""; OUT="-"; READ_ONLY=""; BRIEFS=""; WORK_ROOT=""; MAX_CASES=0; JOBS=4
while [ $# -gt 0 ]; do
    case "$1" in
        --cases) CASES="$2"; shift 2 ;;
        --repo-path) REPO_PATH="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --work-root) WORK_ROOT="$2"; shift 2 ;;
        --max-cases) MAX_CASES="$2"; shift 2 ;;
        --jobs) JOBS="$2"; shift 2 ;;
        --read-only) READ_ONLY=1; shift ;;
        --print-briefs) BRIEFS=1; shift ;;
        *) printf 'unknown flag: %s\n' "$1" >&2; exit 1 ;;
    esac
done
[ -n "$CASES" ] || { printf 'need --cases <labelled.jsonl>\n' >&2; exit 1; }
[ -n "$REPO_PATH" ] || REPO_PATH="$HOME/code/sentry"
[ -d "$REPO_PATH/.git" ] || { printf 'no git clone at %s (pass --repo-path)\n' "$REPO_PATH" >&2; exit 1; }
[ -n "$WORK_ROOT" ] || WORK_ROOT="${TMPDIR:-/tmp}/autofix-review-eval"
mkdir -p "$WORK_ROOT"

# The brief every case is judged under. Identical text in both modes, so a
# locally-driven run and an orchestrated one are measuring the same thing.
brief_for() {
    local work="$1" mode="$2" ro="$3"
    cat <<BRIEF
Run the autofix-review skill over the already-gathered inputs in $work.

  - Inputs are collected: read \$work/meta.json and \$work/raw/*. Do NOT re-resolve
    the target, and do NOT read anything about how this PR was reviewed — reviews,
    review comments, later commits, or the merged state. You are judging the code
    as it stood before any human saw it.
  - MODE is $mode.
  - Run Wave 1 (four BLIND card writers), Wave 2 (L1 L2 L3 L4a L4b + P + S),
    $( [ -n "$ro" ] && printf 'SKIP Wave 3 (probes): this is a read-only scoring run.' \
                   || printf 'Wave 3 (probes) where a claim is testable,' )
    then Wave 4 (refute every broken link).
  - Write every card, link, probe and refutation as JSON under \$work, per
    $SKILL_DIR/reference/cards.md.
  - Do not write the verdict yourself. verdict-rule.sh produces it.
BRIEF
}

prepare_case() {   # prepare_case <case-json> -> work dir on stdout, or empty
    local c="$1" pr sha base_ref work wt base_sha
    pr="$(printf '%s' "$c" | jq -r '.pr')"
    sha="$(printf '%s' "$c" | jq -r '.head_sha_at_review')"
    base_ref="$(printf '%s' "$c" | jq -r '.base_ref // "master"')"
    work="$WORK_ROOT/pr-$pr"
    wt="$work/tree"
    mkdir -p "$work"

    git -C "$REPO_PATH" cat-file -e "$sha^{commit}" 2>/dev/null || \
        git -C "$REPO_PATH" fetch -q origin "$sha" 2>/dev/null || true
    git -C "$REPO_PATH" cat-file -e "$sha^{commit}" 2>/dev/null || {
        printf 'pr %s: commit %s not in the clone, skipped\n' "$pr" "$sha" >&2; return 1; }

    if [ ! -d "$wt/.git" ] && [ ! -f "$wt/.git" ]; then
        git -C "$REPO_PATH" worktree add --detach --force "$wt" "$sha" >/dev/null 2>&1 || {
            printf 'pr %s: could not create a worktree\n' "$pr" >&2; return 1; }
    fi

    base_sha="$(git -C "$REPO_PATH" merge-base "origin/$base_ref" "$sha" 2>/dev/null || \
                git -C "$REPO_PATH" rev-parse "$sha^" 2>/dev/null || true)"

    "$SKILL_DIR/scripts/gather.sh" --repo-path "$wt" --work "$work" \
        --base "$base_sha" --head "$sha" >/dev/null 2>&1 || {
        printf 'pr %s: gather failed\n' "$pr" >&2; return 1; }

    # The PR body is part of what the intent card must read, and the local clone
    # has no idea what it was. Splice it in from the case record.
    printf '%s' "$c" | jq -r '.body // ""' > "$work/raw/pr-body.md"
    {
        printf '# %s\n\n## Pull request description\n\n' "$(printf '%s' "$c" | jq -r .title)"
        cat "$work/raw/pr-body.md"
        printf '\n\n'
        sed -n '/^## Commit messages/,$p' "$work/raw/body.md"
    } > "$work/raw/body.full.md"
    mv "$work/raw/body.full.md" "$work/raw/body.md"

    printf '%s\n' "$work"
}

emit_prediction() {   # emit_prediction <case-json> <work>
    local c="$1" work="$2" v
    v="$("$SKILL_DIR/scripts/verdict-rule.sh" --work "$work" ${READ_ONLY:+--read-only} --json 2>/dev/null \
         || echo '{"verdict":"error","codes":[],"scored":"","summary":"verdict-rule failed"}')"
    printf '%s' "$c" | jq -c --argjson v "$v" --arg work "$work" \
        '. + {predicted: $v.verdict, predicted_codes: $v.codes, scored: $v.scored,
              predicted_summary: $v.summary, work: $work}'
}

PRED_DIR="$WORK_ROOT/.predictions.$$"
mkdir -p "$PRED_DIR"
trap 'rm -rf "$PRED_DIR"' EXIT

# review_one <case-json> <n> — one whole case, into its own prediction file.
review_one() {
    local c="$1" n="$2" work mode pr
    pr="$(printf '%s' "$c" | jq -r .pr)"
    work="$(prepare_case "$c")" || return 0
    mode="$(jq -r '.mode // "bugfix"' "$work/meta.json")"

    # Settled already? gather.sh knows when the chain has no anchor, and N1
    # outranks anything the review could find. Spending sixteen subagents to
    # reach a verdict already on disk is the most expensive way to learn nothing.
    local pc
    if pc="$("$SKILL_DIR/scripts/verdict-rule.sh" --work "$work" --precheck --json 2>/dev/null)"; then
        printf '%s' "$c" | jq -c --argjson v "$pc" --arg work "$work" \
            '. + {predicted: $v.verdict, predicted_codes: $v.codes, scored: $v.scored,
                  predicted_summary: $v.summary, short_circuit: true, work: $work}' > "$PRED_DIR/$n.json"
        printf '[%s] pr %s -> %s %s (short-circuit, no review run)\n' "$n" "$pr" \
            "$(printf '%s' "$pc" | jq -r .verdict)" "$(printf '%s' "$pc" | jq -r '.codes|join(",")')" >&2
        return 0
    fi

    printf '[%s] pr %s (%s) started\n' "$n" "$pr" "$mode" >&2

    if [ -n "$BRIEFS" ]; then
        printf '%s' "$c" | jq -c --arg work "$work" --arg brief "$(brief_for "$work" "$mode" "$READ_ONLY")" \
            '. + {work: $work, brief: $brief}' > "$PRED_DIR/$n.json"
        return 0
    fi
    claude -p "$(brief_for "$work" "$mode" "$READ_ONLY")" >/dev/null 2>&1 || true
    emit_prediction "$c" "$work" > "$PRED_DIR/$n.json"
    printf '[%s] pr %s -> %s\n' "$n" "$pr" \
        "$(jq -r '.predicted + " " + ((.predicted_codes // []) | join(","))' "$PRED_DIR/$n.json" 2>/dev/null)" >&2
}

if [ -z "$BRIEFS" ] && ! command -v claude >/dev/null 2>&1; then
    printf 'no `claude` on PATH; use --print-briefs and orchestrate the cases yourself\n' >&2
    exit 1
fi

done_n=0
while IFS= read -r c; do
    [ -n "$c" ] || continue
    if [ "$MAX_CASES" -gt 0 ] && [ "$done_n" -ge "$MAX_CASES" ]; then
        printf 'stopping at --max-cases %s\n' "$MAX_CASES" >&2
        break
    fi
    label="$(printf '%s' "$c" | jq -r '.label // ""')"
    # AMBIGUOUS and EXCLUDED cases are kept in the file but never run: they
    # cannot move a precision number, so reviewing them buys nothing.
    case "$label" in ACCEPT_TRUTH|REJECT_TRUTH) : ;; *) continue ;; esac

    # Bounded concurrency, polled rather than `wait -n`, which needs bash 4.3 --
    # macOS still ships 3.2 as /bin/bash and this is meant to run there.
    while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$JOBS" ]; do sleep 0.5; done
    done_n=$((done_n + 1))
    review_one "$c" "$done_n" &
done < "$CASES"
wait

printf 'reviewed %s case(s) at %s at a time\n' "$done_n" "$JOBS" >&2
# Concatenate in case order, not completion order, so a rerun of the same
# sample produces a byte-identical predictions file.
if [ "$(ls -A "$PRED_DIR" 2>/dev/null | wc -l | tr -d ' ')" -gt 0 ]; then
    for n in $(seq 1 "$done_n"); do
        [ -f "$PRED_DIR/$n.json" ] && cat "$PRED_DIR/$n.json"
    done
else
    : # nothing ran; pilot.sh treats an empty predictions file as fatal
fi > >([ "$OUT" = - ] && cat || cat > "$OUT")
wait
