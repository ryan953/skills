#!/usr/bin/env bash
# Tests for sync-check.sh — the only script in this skill that merges and
# pushes on its own, so it's the one whose wiring gets exercised against a
# real repo rather than trusted from the pure decision table alone.
#
# Real git against a local bare "origin"; `gh` is faked so PR-mode tests don't
# need a token or the network. Every scenario gets its own throwaway repo pair
# so a conflict left mid-merge by one test can't bleed into the next.
#
# Run:  skills/local-pr-review/scripts/sync-check.test.sh
# Exit: 0 all pass, 1 any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SYNC="$SCRIPT_DIR/sync-check.sh"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/sync-check-test-XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0
FAIL=0

eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        PASS=$((PASS+1)); printf '  ok   %s\n' "$name"
    else
        FAIL=$((FAIL+1))
        printf '  FAIL %s\n       expected: [%s]\n       actual:   [%s]\n' \
            "$name" "$expected" "$actual"
    fi
}

# A fake gh that answers `pr view --json mergeStateStatus,reviewDecision` from
# $GH_PR_VIEW_JSON and logs every call, so "was GitHub even asked to merge
# anything" is answerable without trusting the script's own report of itself.
GH_LOG="$TMPROOT/gh-calls.log"
mkdir -p "$TMPROOT/bin"
cat > "$TMPROOT/bin/gh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$*" in
    *"pr view"*)
        if [ -n "${GH_PR_VIEW_JSON:-}" ]; then
            printf '%s\n' "$GH_PR_VIEW_JSON"
        else
            printf '{}\n'
        fi
        ;;
    *) printf '{}\n' ;;
esac
FAKE
chmod +x "$TMPROOT/bin/gh"
export GH_LOG
export PATH="$TMPROOT/bin:$PATH"
export LPR_SYNC_POLL_TRIES=1 LPR_SYNC_POLL_SLEEP=0

reset_log() { : > "$GH_LOG"; }
gh_calls() { [ -s "$GH_LOG" ] && cat "$GH_LOG" || printf ''; }

# val <KEY> -> the value of an emitted KEY='value' line in OUT
val() { printf '%s\n' "$OUT" | sed -n "s/^$1='\(.*\)'$/\1/p" | tail -1; }

# require_scratch_dir <path> — every git command below must run inside a
# throwaway repo under $TMPROOT, never the real checkout this test lives in.
# `git -C ""` is a documented no-op (it runs against the caller's cwd), so a
# path that resolved to empty would silently repoint every command that
# follows at whatever repo happens to be running this test — that's not a
# theoretical risk, it's what an earlier version of this file actually did.
require_scratch_dir() {
    case "${1:-}" in
        "$TMPROOT"/*) return 0 ;;
        *) printf 'error: refusing to run git against non-scratch path: [%s]\n' "${1:-}" >&2
           exit 1 ;;
    esac
}

# new_repo_pair <name> — an "origin" bare repo plus a "work" clone, main
# branch seeded with one commit. Prints the work dir's path.
new_repo_pair() {
    local name="$1"
    local base origin work
    base="$TMPROOT/$name"
    origin="$base/origin.git"
    work="$base/work"
    require_scratch_dir "$work"
    git init --bare --initial-branch=main -q "$origin"
    git clone -q "$origin" "$work"
    git -C "$work" config user.email test@example.invalid
    git -C "$work" config user.name "Test"
    printf 'one\n' > "$work/file.txt"
    git -C "$work" add file.txt
    git -C "$work" commit -q -m "initial"
    git -C "$work" push -q origin main
    printf '%s\n' "$work"
}

run_sync() {  # run_sync <work-dir> <args...> ; sets OUT/RC, runs with cwd=work-dir
    local dir="$1"; shift
    require_scratch_dir "$dir"
    OUT="$(cd "$dir" && bash "$SYNC" "$@" 2>&1)"; RC=$?
}

# new_work <name> — sets $WORK to a fresh repo pair's work dir, guarded again
# at the call site rather than trusting new_repo_pair's own internal check.
new_work() { WORK="$(new_repo_pair "$1")"; require_scratch_dir "$WORK"; }

echo "branch mode (no PR) — always class mine"

new_work behind-clean
git -C "$WORK" checkout -q -b feature
printf 'feature change\n' >> "$WORK/other.txt"
git -C "$WORK" add other.txt
git -C "$WORK" commit -q -m "feature work"
# advance main on origin without touching feature, then pull the ref locally.
git -C "$WORK" checkout -q main
printf 'two\n' >> "$WORK/file.txt"
git -C "$WORK" commit -q -am "main moves on"
git -C "$WORK" push -q origin main
git -C "$WORK" checkout -q feature

run_sync "$WORK" --class mine --has-pr no --pushed yes --head feature --base main
eq "behind, unapproved -> merge-master"  merge-master "$(val SYNC_ACTION)"
eq "reported stale"                      yes           "$(val STALE)"
eq "merges cleanly"                      clean         "$(val MERGE_RESULT)"
eq "pushed (branch was already public)"  yes           "$(val JUST_PUSHED)"
eq "origin now has the merge" \
    "$(git -C "$WORK" rev-parse feature)" \
    "$(git -C "$(dirname "$WORK")/origin.git" rev-parse feature)"

new_work behind-unpushed
git -C "$WORK" checkout -q -b feature2
# feature2 never touches origin. Advance main so feature2 falls behind it.
git -C "$WORK" checkout -q main
printf 'two\n' >> "$WORK/file.txt"
git -C "$WORK" commit -q -am "main moves on"
git -C "$WORK" push -q origin main
git -C "$WORK" checkout -q feature2
run_sync "$WORK" --class mine --has-pr no --pushed no --head feature2 --base main
eq "unpushed branch: still merges"       clean "$(val MERGE_RESULT)"
eq "unpushed branch: never auto-pushed"  no    "$(val JUST_PUSHED)"

new_work conflict
git -C "$WORK" checkout -q -b feature
printf 'feature version\n' > "$WORK/file.txt"
git -C "$WORK" commit -q -am "feature edits file.txt"
git -C "$WORK" checkout -q main
printf 'main version\n' > "$WORK/file.txt"
git -C "$WORK" commit -q -am "main edits file.txt too"
git -C "$WORK" push -q origin main
git -C "$WORK" checkout -q feature
run_sync "$WORK" --class mine --has-pr no --pushed yes --head feature --base main
eq "conflicting merge is attempted"      merge-master "$(val SYNC_ACTION)"
eq "reports conflict, not clean"         conflict     "$(val MERGE_RESULT)"
eq "names the conflicted file"           "file.txt"   "$(val CONFLICT_FILES | tr -d ' ')"
eq "never pushes a conflicted merge"     no            "$(val JUST_PUSHED)"
eq "leaves the merge in progress for the caller" \
    0 "$(cd "$WORK" && git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; echo $?)"

new_work clean-uptodate
git -C "$WORK" checkout -q -b feature
run_sync "$WORK" --class mine --has-pr no --pushed yes --head feature --base main
eq "up to date -> no action"             none    "$(val SYNC_ACTION)"
eq "not stale"                           no      "$(val STALE)"
eq "merge skipped"                       skipped "$(val MERGE_RESULT)"

echo
echo "PR mode"

new_work pr-behind-unapproved
git -C "$WORK" checkout -q -b feature
git -C "$WORK" push -q origin feature
git -C "$WORK" checkout -q main
printf 'two\n' >> "$WORK/file.txt"
git -C "$WORK" commit -q -am "main moves on"
git -C "$WORK" push -q origin main
git -C "$WORK" checkout -q feature

reset_log
export GH_PR_VIEW_JSON='{"mergeStateStatus":"BEHIND","reviewDecision":null}'
run_sync "$WORK" --class mine --has-pr yes --pushed yes --head feature --base main --pr 1 --repo o/r
eq "PR mode reads GitHub's own state"    merge-master "$(val SYNC_ACTION)"
eq "merges cleanly"                      clean        "$(val MERGE_RESULT)"
eq "PR mode always pushes on a clean merge" yes       "$(val JUST_PUSHED)"

new_work pr-behind-approved
git -C "$WORK" checkout -q -b feature
git -C "$WORK" push -q origin feature
reset_log
export GH_PR_VIEW_JSON='{"mergeStateStatus":"BEHIND","reviewDecision":"APPROVED"}'
run_sync "$WORK" --class mine --has-pr yes --pushed yes --head feature --base main --pr 2 --repo o/r
eq "stale + approved -> left alone"      none    "$(val SYNC_ACTION)"
eq "nothing merged"                      skipped "$(val MERGE_RESULT)"
eq "no git mutation: HEAD unchanged" \
    "$(git -C "$WORK" rev-parse HEAD)" "$(git -C "$WORK" rev-parse feature)"

new_work pr-other-dirty
git -C "$WORK" checkout -q -b feature
BEFORE="$(git -C "$WORK" rev-parse HEAD)"
reset_log
export GH_PR_VIEW_JSON='{"mergeStateStatus":"DIRTY","reviewDecision":null}'
run_sync "$WORK" --class other --has-pr yes --pushed yes --head feature --base main --pr 3 --repo o/r
eq "someone else's conflicted PR -> notify only" notify "$(val SYNC_ACTION)"
eq "conflicts reported"                          yes    "$(val CONFLICTS)"
eq "never touches their tree"                    "$BEFORE" "$(git -C "$WORK" rev-parse HEAD)"
eq "no merge attempted (no gh mutation either)" "" \
    "$(gh_calls | grep -v 'pr view' || true)"

new_work pr-other-clean
git -C "$WORK" checkout -q -b feature
reset_log
export GH_PR_VIEW_JSON='{"mergeStateStatus":"CLEAN","reviewDecision":null}'
run_sync "$WORK" --class other --has-pr yes --pushed yes --head feature --base main --pr 4 --repo o/r
eq "someone else's clean PR -> nothing to say" none "$(val SYNC_ACTION)"

echo
printf 'passed: %s   failed: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
