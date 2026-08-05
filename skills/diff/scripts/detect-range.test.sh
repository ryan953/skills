#!/usr/bin/env bash
# Tests for detect-range.sh. Builds throwaway git repos in a temp dir, runs the
# detector, and asserts the exact revdiff args (and range summary) it produces.
#
# Run:  skills/diff/scripts/detect-range.test.sh
# Exit: 0 all pass, 1 any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DETECT="$SCRIPT_DIR/detect-range.sh"

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/detect-range-test-XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0
FAIL=0

# Run detector in $1 (repo dir), with remaining args as detector args. Sets
# ARGS_OUT (newline-joined arg records) and RANGE_OUT.
run() {
    local dir="$1"; shift
    local out
    out="$(cd "$dir" && bash "$DETECT" "$@" 2>/dev/null)"
    ARGS_OUT="$(printf '%s\n' "$out" | awk -F'\t' '$1=="arg"{print $2}')"
    RANGE_OUT="$(printf '%s\n' "$out" | awk -F'\t' '$1=="range"{print $2}')"
}

# assert_args <name> <expected newline-joined args>
assert_args() {
    local name="$1" expected="$2"
    if [ "$ARGS_OUT" = "$expected" ]; then
        PASS=$((PASS+1)); printf '  ok   %s\n' "$name"
    else
        FAIL=$((FAIL+1))
        printf '  FAIL %s\n       expected: [%s]\n       actual:   [%s]\n' \
            "$name" "$(printf '%s' "$expected" | tr '\n' '|')" \
            "$(printf '%s' "$ARGS_OUT" | tr '\n' '|')"
    fi
}

# assert_range_contains <name> <substring>
assert_range_contains() {
    local name="$1" sub="$2"
    case "$RANGE_OUT" in
        *"$sub"*) PASS=$((PASS+1)); printf '  ok   %s (range)\n' "$name" ;;
        *) FAIL=$((FAIL+1)); printf '  FAIL %s (range)\n       want substr: [%s]\n       range:       [%s]\n' \
               "$name" "$sub" "$RANGE_OUT" ;;
    esac
}

# Make a fresh git repo at $1 with default branch name $2 (main|master).
newrepo() {
    local dir="$1" trunk="${2:-main}"
    mkdir -p "$dir"; git -C "$dir" init -q -b "$trunk"
    git -C "$dir" config user.email t@t; git -C "$dir" config user.name t
}
commit() { git -C "$1" add -A; git -C "$1" commit -qm "${2:-c}"; }
sha()    { git -C "$1" rev-parse "${2:-HEAD}"; }

# Fake an origin in repo $1: point refs/remotes/origin/$2 at commit $3 and make it
# origin/HEAD's target. No network or bare repo needed — detection only reads these
# refs via show-ref / symbolic-ref / merge-base.
fake_origin() {
    git -C "$1" update-ref "refs/remotes/origin/$2" "$3"
    git -C "$1" symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$2"
}

# ---------------------------------------------------------------------------
echo "detect-range.sh tests"

# 1. Fresh repo, no commits → --all-files
R="$TMPROOT/fresh"; newrepo "$R" main
printf 'x\n' > "$R/a.txt"
run "$R"
assert_args "fresh repo (no commits)" "--all-files"

# 2. Trunk (main), clean → HEAD~1
R="$TMPROOT/main-clean"; newrepo "$R" main
printf 'a\n' > "$R/f.txt"; commit "$R"
run "$R"
assert_args "main + clean" "HEAD~1"

# 3. Trunk (main), unstaged change → HEAD --untracked
R="$TMPROOT/main-unstaged"; newrepo "$R" main
printf 'a\n' > "$R/f.txt"; commit "$R"
printf 'a\nb\n' > "$R/f.txt"
run "$R"
assert_args "main + unstaged" "$(printf 'HEAD\n--untracked')"

# 4. Trunk (main), STAGED-ONLY change → HEAD --untracked (the staged bug fix:
#    HEAD base sees staged content; no-arg default would show nothing)
R="$TMPROOT/main-staged"; newrepo "$R" main
printf 'a\n' > "$R/f.txt"; commit "$R"
printf 'a\nb\n' > "$R/f.txt"; git -C "$R" add f.txt
run "$R"
assert_args "main + staged-only" "$(printf 'HEAD\n--untracked')"

# 5. Trunk (main), untracked new file only → HEAD --untracked
R="$TMPROOT/main-untracked"; newrepo "$R" main
printf 'a\n' > "$R/f.txt"; commit "$R"
printf 'new\n' > "$R/new.txt"
run "$R"
assert_args "main + untracked new file" "$(printf 'HEAD\n--untracked')"
assert_range_contains "main + untracked new file" "untracked"

# 6. Default branch named master, clean → HEAD~1
R="$TMPROOT/master-clean"; newrepo "$R" master
printf 'a\n' > "$R/f.txt"; commit "$R"
run "$R"
assert_args "master (default) + clean" "HEAD~1"

# 7. Feature branch off main → merge-base + --untracked
R="$TMPROOT/feat-main"; newrepo "$R" main
printf 'a\n' > "$R/f.txt"; commit "$R" base
BASE_SHA="$(git -C "$R" rev-parse HEAD)"
git -C "$R" checkout -q -b feature
printf 'a\nb\n' > "$R/f.txt"; commit "$R" work
run "$R"
assert_args "feature branch off main" "$(printf '%s\n--untracked' "$BASE_SHA")"
assert_range_contains "feature branch off main" "full branch diff"

# 8. Feature branch off master (repo uses master as trunk)
R="$TMPROOT/feat-master"; newrepo "$R" master
printf 'a\n' > "$R/f.txt"; commit "$R" base
BASE_SHA="$(git -C "$R" rev-parse HEAD)"
git -C "$R" checkout -q -b feature
printf 'a\nb\n' > "$R/f.txt"; commit "$R" work
run "$R"
assert_args "feature branch off master" "$(printf '%s\n--untracked' "$BASE_SHA")"

# 9. Feature branch, dirty → still merge-base + --untracked, range notes uncommitted
R="$TMPROOT/feat-dirty"; newrepo "$R" main
printf 'a\n' > "$R/f.txt"; commit "$R" base
BASE_SHA="$(git -C "$R" rev-parse HEAD)"
git -C "$R" checkout -q -b feature
printf 'a\nb\n' > "$R/f.txt"; commit "$R" work
printf 'a\nb\nc\n' > "$R/f.txt"      # uncommitted on top
run "$R"
assert_args "feature branch + dirty" "$(printf '%s\n--untracked' "$BASE_SHA")"
assert_range_contains "feature branch + dirty" "uncommitted"

# 10. Detached branch with NO resolvable main (branch 'work', no main/master,
#     no origin) → must NOT fabricate a ref; falls to trunk arm.
#     clean → HEAD~1.
R="$TMPROOT/nomain-clean"; newrepo "$R" work
printf 'a\n' > "$R/f.txt"; commit "$R" one
printf 'a\nb\n' > "$R/f.txt"; commit "$R" two
run "$R"
assert_args "no resolvable main + clean" "HEAD~1"

# 11. No resolvable main, dirty → HEAD --untracked (never a bogus 'main' ref)
R="$TMPROOT/nomain-dirty"; newrepo "$R" work
printf 'a\n' > "$R/f.txt"; commit "$R" one
printf 'a\nb\n' > "$R/f.txt"
run "$R"
assert_args "no resolvable main + dirty" "$(printf 'HEAD\n--untracked')"

# 12. One-arg bare ref → base + --untracked (base..worktree, show new files)
R="$TMPROOT/onearg-ref"; newrepo "$R" main
printf 'a\n' > "$R/f.txt"; commit "$R" one
printf 'a\nb\n' > "$R/f.txt"; commit "$R" two
run "$R" HEAD~1
assert_args "one-arg ref (base..worktree)" "$(printf 'HEAD~1\n--untracked')"

# 13. One-arg existing file path → --only, no --untracked
R="$TMPROOT/onearg-file"; newrepo "$R" main
printf 'hello\n' > "$R/README.md"; commit "$R"
run "$R" README.md
assert_args "one-arg file path" "--only=README.md"

# 14. One-arg path-like token that isn't a ref and doesn't exist → --only
R="$TMPROOT/onearg-pathlike"; newrepo "$R" main
printf 'a\n' > "$R/f.txt"; commit "$R"
run "$R" docs/plan.md
assert_args "one-arg nonexistent path-like" "--only=docs/plan.md"

# 15. Two-arg explicit range → both refs, NO --untracked (historical diff)
R="$TMPROOT/tworef"; newrepo "$R" main
printf 'a\n' > "$R/f.txt"; commit "$R" one
printf 'a\nb\n' > "$R/f.txt"; commit "$R" two
run "$R" HEAD~1 HEAD
assert_args "two-arg explicit range" "$(printf 'HEAD~1\nHEAD')"

# 16. Bad arg count → nonzero exit
R="$TMPROOT/badargs"; newrepo "$R" main
printf 'a\n' > "$R/f.txt"; commit "$R"
if (cd "$R" && bash "$DETECT" a b c >/dev/null 2>&1); then
    FAIL=$((FAIL+1)); printf '  FAIL too many args (should exit nonzero)\n'
else
    PASS=$((PASS+1)); printf '  ok   too many args exits nonzero\n'
fi

# --- fork point: the local and remote spellings of the trunk drift apart --------

# 17. STALE local trunk. Branch forked off origin/master, but local master was left
#     55-commits-ago behind. Base must be origin/master's tip (the real fork point),
#     NOT local master — otherwise every upstream commit since shows up as "mine".
R="$TMPROOT/stale-local-trunk"; newrepo "$R" master
printf 'a\n' > "$R/f.txt"; commit "$R" old-trunk       # local master parks here
git -C "$R" checkout -q -b feature
printf 'b\n' > "$R/up1.txt"; commit "$R" upstream1     # commits that landed on
printf 'c\n' > "$R/up2.txt"; commit "$R" upstream2     # origin/master since
FORK_SHA="$(sha "$R")"
fake_origin "$R" master "$FORK_SHA"
printf 'd\n' > "$R/mine.txt"; commit "$R" mine
run "$R"
assert_args "stale local trunk → fork point is origin/master" "$(printf '%s\n--untracked' "$FORK_SHA")"
assert_range_contains "stale local trunk → fork point is origin/master" "origin/master..feature"

# 18. Local trunk AHEAD of origin (committed to master, not pushed) and the branch
#     forked off that local work. Base must be local master, not origin/master.
R="$TMPROOT/ahead-local-trunk"; newrepo "$R" master
printf 'a\n' > "$R/f.txt"; commit "$R" pushed
fake_origin "$R" master "$(sha "$R")"
printf 'b\n' > "$R/local.txt"; commit "$R" unpushed-trunk
FORK_SHA="$(sha "$R")"
git -C "$R" checkout -q -b feature
printf 'c\n' > "$R/mine.txt"; commit "$R" mine
run "$R"
assert_args "local trunk ahead of origin → fork point is local trunk" "$(printf '%s\n--untracked' "$FORK_SHA")"

# 19. Local trunk DIVERGED (has a commit the branch never saw) while origin/master
#     moved on. Descendant-most merge-base still wins.
R="$TMPROOT/diverged-local-trunk"; newrepo "$R" master
printf 'a\n' > "$R/f.txt"; commit "$R" root
git -C "$R" checkout -q -b feature
printf 'b\n' > "$R/up.txt"; commit "$R" upstream
FORK_SHA="$(sha "$R")"
fake_origin "$R" master "$FORK_SHA"
git -C "$R" checkout -q master
printf 'z\n' > "$R/only-local.txt"; commit "$R" local-only-trunk-commit
git -C "$R" checkout -q feature
printf 'c\n' > "$R/mine.txt"; commit "$R" mine
run "$R"
assert_args "diverged local trunk → fork point is origin/master" "$(printf '%s\n--untracked' "$FORK_SHA")"

# 20. Only origin/master exists (no local trunk branch at all — a common worktree
#     shape). Must still resolve a fork point from the remote-tracking ref.
R="$TMPROOT/remote-only-trunk"; newrepo "$R" master
printf 'a\n' > "$R/f.txt"; commit "$R" root
FORK_SHA="$(sha "$R")"
git -C "$R" checkout -q -b feature
printf 'b\n' > "$R/mine.txt"; commit "$R" mine
git -C "$R" branch -q -D master
fake_origin "$R" master "$FORK_SHA"
run "$R"
assert_args "remote-only trunk → fork point from origin/master" "$(printf '%s\n--untracked' "$FORK_SHA")"

# 21. ON trunk with unpushed commits → still the trunk arm (HEAD~1), not a
#     "branch diff" against origin. Being on trunk is decided by branch name.
R="$TMPROOT/on-trunk-unpushed"; newrepo "$R" master
printf 'a\n' > "$R/f.txt"; commit "$R" pushed
fake_origin "$R" master "$(sha "$R")"
printf 'b\n' > "$R/f.txt"; commit "$R" unpushed
run "$R"
assert_args "on trunk + unpushed commits" "HEAD~1"

# 22. Feature branch holding nothing of its own (fork point == HEAD) but dirty →
#     trunk arm, so uncommitted work still shows instead of an empty range.
R="$TMPROOT/feat-no-commits"; newrepo "$R" main
printf 'a\n' > "$R/f.txt"; commit "$R" root
git -C "$R" checkout -q -b feature
printf 'a\nb\n' > "$R/f.txt"
run "$R"
assert_args "feature branch with no own commits + dirty" "$(printf 'HEAD\n--untracked')"

# 23. Local trunk fully up to date with origin (both merge-bases identical) → the
#     authoritative ref wins the label, so the summary reads origin/master.
R="$TMPROOT/synced-trunk"; newrepo "$R" master
printf 'a\n' > "$R/f.txt"; commit "$R" root
FORK_SHA="$(sha "$R")"
fake_origin "$R" master "$FORK_SHA"
git -C "$R" checkout -q -b feature
printf 'b\n' > "$R/mine.txt"; commit "$R" mine
run "$R"
assert_args "synced local trunk → fork point" "$(printf '%s\n--untracked' "$FORK_SHA")"
assert_range_contains "synced local trunk → labels origin" "origin/master..feature"

# ---------------------------------------------------------------------------
echo ""
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
