#!/usr/bin/env bash
# probe-run.sh — run one probe test against base and head, and enforce the gate
# that makes the result mean anything.
#
# The gate: **the probe must FAIL against base.** A probe that passes before the
# change tells you nothing about the change — it is a green checkmark measuring
# the wrong thing. When that happens the honest conclusion is that our repro (or
# the evidence card it came from) is wrong, so the probe is discarded and the
# evidence link is marked unsupported. It is never reported as a finding about
# the diff.
#
# Usage:
#   probe-run.sh --work <dir> --id p1 --test <file> --runner '<cmd>'
#                [--link L4b] [--repo-path <dir>] [--base <sha>] [--head <sha>]
#                [--dest <path-in-tree>] [--keep-worktrees]
#
# --link names the link this probe backs. verdict-rule.sh joins on it, and
# without it a proven-reject here would be credited to every broken link at once.
#
# `{}` in --runner is replaced with the probe's path inside the worktree; with no
# `{}` the path is appended. The runner is invoked with the worktree as cwd.
#
# Exit: 0 proven | 1 proven-reject | 2 invalid | 3 unprovable
# Writes: $WORK/probes/<id>.json

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../../local-pr-review/scripts/lib.sh"
if [ -f "$LIB" ]; then . "$LIB"; else
    sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
    emit() { printf "%s=%s\n" "$1" "$(sq "${2-}")"; }
    die() { printf 'error: %s\n' "$*" >&2; exit 3; }
fi

WORK=""; ID=""; TEST=""; RUNNER=""; REPO_PATH=""; BASE=""; HEAD=""; DEST=""; KEEP=""; LINK=""
while [ $# -gt 0 ]; do
    case "$1" in
        --work) WORK="$2"; shift 2 ;;
        --id) ID="$2"; shift 2 ;;
        --test) TEST="$2"; shift 2 ;;
        --runner) RUNNER="$2"; shift 2 ;;
        --repo-path) REPO_PATH="$2"; shift 2 ;;
        --base) BASE="$2"; shift 2 ;;
        --head) HEAD="$2"; shift 2 ;;
        --dest) DEST="$2"; shift 2 ;;
        --link) LINK="$2"; shift 2 ;;
        --keep-worktrees) KEEP=1; shift ;;
        *) die "unknown flag: $1" ;;
    esac
done

[ -n "$WORK" ]   || die "need --work"
[ -n "$ID" ]     || die "need --id"
[ -n "$TEST" ]   || die "need --test"
[ -n "$RUNNER" ] || die "need --runner"
[ -f "$TEST" ]   || die "probe file not found: $TEST"

META="$WORK/meta.json"
if [ -f "$META" ]; then
    [ -n "$BASE" ]      || BASE="$(jq -r '.base_sha // ""' "$META")"
    [ -n "$HEAD" ]      || HEAD="$(jq -r '.head_sha // ""' "$META")"
    [ -n "$REPO_PATH" ] || REPO_PATH="$(jq -r '.repo_path // ""' "$META")"
fi
[ -n "$REPO_PATH" ] || REPO_PATH="$(pwd)"
[ -n "$BASE" ] && [ -n "$HEAD" ] || die "need --base and --head (or a meta.json carrying them)"

mkdir -p "$WORK/probes"
RESULT_FILE="$WORK/probes/$ID.json"

# Where the probe lives inside the tree. Next to the first changed file by
# default, so relative imports and the project's test-path globs both resolve
# the way they would for a real test in that package.
if [ -z "$DEST" ]; then
    FIRST="$(head -n1 "$WORK/raw/files.txt" 2>/dev/null || true)"
    if [ -n "$FIRST" ] && [ "$(dirname "$FIRST")" != "." ]; then
        DEST="$(dirname "$FIRST")/$(basename "$TEST")"
    else
        DEST="$(basename "$TEST")"
    fi
fi

# ---- worktrees --------------------------------------------------------------
# Off the existing clone, never a fresh one: on a monorepo a re-clone costs
# minutes and gigabytes, and the point of --repo-path is that the user already
# paid for it once.
add_worktree() {
    local dir="$1" sha="$2"
    if [ -d "$dir/.git" ] || [ -f "$dir/.git" ]; then
        git -C "$dir" checkout -q --detach "$sha" 2>/dev/null && return 0
        git -C "$REPO_PATH" worktree remove --force "$dir" >/dev/null 2>&1 || true
    fi
    git -C "$REPO_PATH" worktree add --detach --force "$dir" "$sha" >/dev/null 2>&1
}

WT_BASE="$WORK/wt-base"
WT_HEAD="$WORK/wt-head"

write_result() {   # write_result <outcome> <base> <head> <detail>
    jq -n --arg id "$ID" --arg tf "$(basename "$TEST")" --arg o "$1" \
          --arg b "$2" --arg h "$3" --arg d "$4" --arg dest "$DEST" --arg link "$LINK" \
        '{id:$id, link:$link, test_file:$tf, dest:$dest, base_result:$b, head_result:$h,
          outcome:$o, detail:$d}' > "$RESULT_FILE"
    emit PROBE_ID "$ID"; emit OUTCOME "$1"; emit BASE_RESULT "$2"
    emit HEAD_RESULT "$3"; emit RESULT_FILE "$RESULT_FILE"
    case "$1" in
        proven) exit 0 ;; proven-reject) exit 1 ;; invalid) exit 2 ;; *) exit 3 ;;
    esac
}

# run_probe <worktree> — echoes pass|fail|error, and leaves the run's output in
# the file named by $OUT_CAPTURE.
#
# A file rather than a variable because callers read this function through a
# command substitution, which runs it in a subshell: anything it assigned to a
# global was discarded the moment it returned, so every record's `detail` shipped
# as "still failing at head: " with the diagnostic silently dropped.
#
# `error` is kept distinct from `fail` on purpose: a suite that never ran is not
# evidence of anything, and collapsing the two is how "we could not check" turns
# into "we checked and it is broken".
OUT_CAPTURE=""
run_probe() {
    local wt="$1" cmd out rc
    cp "$TEST" "$wt/$DEST" 2>/dev/null || { mkdir -p "$wt/$(dirname "$DEST")" && cp "$TEST" "$wt/$DEST"; }
    case "$RUNNER" in
        *"{}"*) cmd="${RUNNER//\{\}/$DEST}" ;;
        *)      cmd="$RUNNER $DEST" ;;
    esac
    out="$(cd "$wt" && eval "$cmd" 2>&1)"
    rc=$?
    rm -f "$wt/$DEST"
    printf '%s' "$out" > "$OUT_CAPTURE"
    if [ "$rc" -eq 0 ]; then printf 'pass\n'; return; fi
    if [ "$rc" -eq 127 ] || printf '%s' "$out" | grep -qiE \
        'command not found|cannot find module|no tests? found|module not found|unable to resolve|econnrefused'; then
        printf 'error\n'; return
    fi
    printf 'fail\n'
}

trim() { tail -n 20 "$1" 2>/dev/null | cut -c1-400 | tr '\n' ' '; }

cleanup() {
    rm -f "$WORK/probes/.$ID.base.out" "$WORK/probes/.$ID.head.out"
    [ -n "$KEEP" ] && return 0
    git -C "$REPO_PATH" worktree remove --force "$WT_BASE" >/dev/null 2>&1 || true
    git -C "$REPO_PATH" worktree remove --force "$WT_HEAD" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ---- base first -------------------------------------------------------------
if ! add_worktree "$WT_BASE" "$BASE"; then
    write_result unprovable error skipped "could not create a worktree at base $BASE"
fi
OUT_CAPTURE="$WORK/probes/.$ID.base.out"
BASE_RESULT="$(run_probe "$WT_BASE")"
BASE_OUT="$OUT_CAPTURE"

if [ "$BASE_RESULT" = error ]; then
    write_result unprovable error skipped "the probe could not run against base: $(trim "$BASE_OUT")"
fi
if [ "$BASE_RESULT" = pass ]; then
    # The gate. Discarded, and reported as a problem with our inputs rather than
    # with the diff — see reference/probes.md.
    write_result invalid pass skipped \
        "the probe passes against base, so it does not reproduce the reported failure; discard it and mark the evidence link unsupported"
fi

# ---- then head --------------------------------------------------------------
if ! add_worktree "$WT_HEAD" "$HEAD"; then
    write_result unprovable fail error "could not create a worktree at head $HEAD"
fi
OUT_CAPTURE="$WORK/probes/.$ID.head.out"
HEAD_RESULT="$(run_probe "$WT_HEAD")"
HEAD_OUT="$OUT_CAPTURE"

case "$HEAD_RESULT" in
    error) write_result unprovable fail error "the probe could not run against head: $(trim "$HEAD_OUT")" ;;
    pass)  write_result proven fail pass "fails at base, passes at head" ;;
    fail)  write_result proven-reject fail fail "still failing at head: $(trim "$HEAD_OUT")" ;;
esac
