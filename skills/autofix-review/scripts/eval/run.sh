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

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"          # .../scripts/eval
# Two levels, not one: $HERE is scripts/eval, so `$HERE/..` is scripts/ and
# every path built from it came out as scripts/scripts/... . Nothing caught it
# because the failure is a stderr line per case and an empty predictions file,
# which score.sh then reports as "no scored cases" -- indistinguishable from a
# sample that legitimately had nothing in it.
SKILL_DIR="$(cd "$HERE/../.." && pwd)"

CASES=""; REPO_PATH=""; OUT="-"; READ_ONLY=""; BRIEFS=""; WORK_ROOT=""; MAX_CASES=0
while [ $# -gt 0 ]; do
    case "$1" in
        --cases) CASES="$2"; shift 2 ;;
        --repo-path) REPO_PATH="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --work-root) WORK_ROOT="$2"; shift 2 ;;
        --max-cases) MAX_CASES="$2"; shift 2 ;;
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

{
    done_n=0
    while IFS= read -r c; do
        [ -n "$c" ] || continue
        # Each case is a full four-wave review. Without a cap, sample size is set
        # by a gh page limit, which is not where that decision belongs.
        if [ "$MAX_CASES" -gt 0 ] && [ "$done_n" -ge "$MAX_CASES" ]; then
            printf 'stopping at --max-cases %s; %s case(s) left unrun\n' "$MAX_CASES" \
                "$(($(wc -l < "$CASES") - done_n))" >&2
            break
        fi
        label="$(printf '%s' "$c" | jq -r '.label // ""')"
        # AMBIGUOUS and EXCLUDED cases are kept in the file but never run: they
        # cannot move a precision number, so paying for a review of them buys
        # nothing.
        case "$label" in ACCEPT_TRUTH|REJECT_TRUTH) : ;; *) continue ;; esac

        work="$(prepare_case "$c")" || continue
        mode="$(jq -r '.mode // "bugfix"' "$work/meta.json")"
        done_n=$((done_n + 1))
        # The review stage is the long one and printed nothing until it finished,
        # so a run in progress was indistinguishable from a hung one.
        printf '[%s] pr %s (%s) ...\n' "$done_n" "$(printf '%s' "$c" | jq -r .pr)" "$mode" >&2

        if [ -n "$BRIEFS" ]; then
            printf '%s' "$c" | jq -c --arg work "$work" --arg brief "$(brief_for "$work" "$mode" "$READ_ONLY")" \
                '. + {work: $work, brief: $brief}'
            continue
        fi

        if command -v claude >/dev/null 2>&1; then
            claude -p "$(brief_for "$work" "$mode" "$READ_ONLY")" >/dev/null 2>&1 || true
        else
            printf 'no `claude` on PATH; use --print-briefs and orchestrate the cases yourself\n' >&2
            exit 1
        fi
        emit_prediction "$c" "$work"
        printf '[%s] pr %s -> %s\n' "$done_n" "$(printf '%s' "$c" | jq -r .pr)" \
            "$("$SKILL_DIR/scripts/verdict-rule.sh" --work "$work" ${READ_ONLY:+--read-only} --json 2>/dev/null | jq -r '.verdict + " " + (.codes|join(","))')" >&2
    done < "$CASES"
} > >([ "$OUT" = - ] && cat || cat > "$OUT")
wait
