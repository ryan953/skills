#!/usr/bin/env bash
# detect-range.sh — compute the revdiff argv + a human range summary for the
# current git repo state. Git-only by design (the /diff skill is git-centric).
#
# Kept separate from diff.sh so it can be unit-tested without a tmux server or
# the revdiff binary: it reads repo state and prints the decision, nothing else.
#
# Usage:
#   detect-range.sh                 # implied range (detection below)
#   detect-range.sh <base>          # diff <base> against the working tree
#   detect-range.sh <base> <against># explicit two-ref (historical) diff
#   detect-range.sh <path>          # single-file context review (--only)
#
# Output (stdout, TAB-separated records, in order):
#   range<TAB><human description>
#   arg<TAB><revdiff arg>           # zero or more, in argv order
#
# The caller collects every `arg` line into revdiff's argv (then appends its
# own --output=). --output is intentionally NOT emitted here.
#
# Detection rules (no args), all git:
#   - no commits yet          → --all-files            (browse everything)
#   - feature branch          → <merge-base main HEAD> --untracked
#                               (whole branch vs main, incl. staged/unstaged/new)
#   - on trunk, dirty         → HEAD --untracked
#                               (HEAD..worktree: staged + unstaged + new files)
#   - on trunk, clean         → HEAD~1                 (last commit)
#
# "Working-tree-ending" ranges get --untracked so brand-new unstaged files show
# up. Using an explicit base (HEAD / merge-base) rather than no-arg means STAGED
# changes are included too — revdiff's no-arg default only shows unstaged.

set -euo pipefail

emit_range() { printf 'range\t%s\n' "$1"; }
emit_arg()   { printf 'arg\t%s\n' "$1"; }

is_ref() { git rev-parse --verify --quiet "$1^{commit}" >/dev/null 2>&1; }

# Echo the trunk branch name, or nothing if none is resolvable. Never fabricates
# a name: origin/HEAD is authoritative; otherwise probe for a real local branch.
resolve_main() {
    local rh
    if rh="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null)"; then
        printf '%s\n' "${rh##refs/remotes/origin/}"
    elif git show-ref --verify --quiet refs/heads/main 2>/dev/null; then
        echo main
    elif git show-ref --verify --quiet refs/heads/master 2>/dev/null; then
        echo master
    fi
}

has_commits() { git rev-parse --verify --quiet HEAD >/dev/null 2>&1; }
is_dirty()    { [ -n "$(git status --porcelain 2>/dev/null)" ]; }

detect_implied() {
    # Fresh repo (no commits): nothing to diff against — browse all files.
    if ! has_commits; then
        emit_range "all files (fresh repo, no commits)"
        emit_arg   "--all-files"
        return
    fi

    local mb branch base
    mb="$(resolve_main)"
    branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"

    # Feature branch: whole branch vs main. Requires a resolvable main AND a
    # real merge-base; either missing → fall through to the trunk/worktree arm
    # rather than passing a ref that doesn't exist.
    if [ -n "$mb" ] && [ "$branch" != "$mb" ] \
        && base="$(git merge-base "$mb" HEAD 2>/dev/null)"; then
        emit_arg "$base"
        emit_arg "--untracked"
        if is_dirty; then
            emit_range "$mb..$branch branch diff + uncommitted (base $base)"
        else
            emit_range "$mb..$branch full branch diff (base $base)"
        fi
        return
    fi

    # Trunk (or no resolvable main): dirty → HEAD..worktree, clean → last commit.
    if is_dirty; then
        emit_arg "HEAD"
        emit_arg "--untracked"
        emit_range "working tree vs HEAD (staged + unstaged + untracked)"
    else
        emit_arg "HEAD~1"
        emit_range "HEAD~1..HEAD (last commit)"
    fi
}

case "$#" in
    0)
        detect_implied
        ;;
    1)
        arg="$1"
        # File path (single-file review) vs a ref. A path exists on disk, or is
        # a non-ref token that looks path-like (has a / or .).
        if [ -f "$arg" ] || { [ ! -e "$arg" ] && ! is_ref "$arg" && printf '%s' "$arg" | grep -q '[/.]'; }; then
            emit_arg "--only=$arg"
            emit_range "single file: $arg"
        else
            # base..worktree → show new files too
            emit_arg "$arg"
            emit_arg "--untracked"
            emit_range "$arg..working tree"
        fi
        ;;
    2)
        # Explicit two-ref historical diff: no working tree involved, so no
        # --untracked.
        emit_arg "$1"
        emit_arg "$2"
        emit_range "$1..$2"
        ;;
    *)
        echo "error: expected 0, 1, or 2 arguments, got $#" >&2
        exit 2
        ;;
esac
