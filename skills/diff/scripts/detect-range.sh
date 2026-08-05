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
#   - feature branch          → <fork point> --untracked
#                               (whole branch vs trunk, incl. staged/unstaged/new)
#   - on trunk, dirty         → HEAD --untracked
#                               (HEAD..worktree: staged + unstaged + new files)
#   - on trunk, clean         → HEAD~1                 (last commit)
#
# The feature-branch base is the branch's *fork point* — where it actually left
# the trunk — not a plain `merge-base master HEAD`. See resolve_fork_point.
#
# "Working-tree-ending" ranges get --untracked so brand-new unstaged files show
# up. Using an explicit base (HEAD / merge-base) rather than no-arg means STAGED
# changes are included too — revdiff's no-arg default only shows unstaged.

set -euo pipefail

emit_range() { printf 'range\t%s\n' "$1"; }
emit_arg()   { printf 'arg\t%s\n' "$1"; }

is_ref() { git rev-parse --verify --quiet "$1^{commit}" >/dev/null 2>&1; }

# Echo the trunk branch name(s) this repo plausibly uses, one per line, most
# authoritative first. Never fabricates a name: origin/HEAD's target wins, then
# main/master but only if they exist locally or on origin.
trunk_names() {
    local rh name
    if rh="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null)"; then
        printf '%s\n' "${rh##refs/remotes/origin/}"
    fi
    for name in main master; do
        if git show-ref --verify --quiet "refs/heads/$name" 2>/dev/null \
            || git show-ref --verify --quiet "refs/remotes/origin/$name" 2>/dev/null; then
            printf '%s\n' "$name"
        fi
    done
}

# Echo "<sha><TAB><ref>": the commit this branch actually forked off the trunk at,
# and the trunk ref that produced it. Reads trunk names (one per line) from $1.
#
# Why not just `merge-base master HEAD`: BOTH refs that spell the trunk have to be
# considered. A local `master` goes stale the second you fetch without pulling, and
# `merge-base` against a stale local trunk lands far behind the real fork point —
# dragging in every upstream commit since as if this branch had authored it (in a
# 55-commit-behind checkout: 322 files instead of 7). The reverse also happens: a
# local trunk can hold work that origin hasn't seen, or origin can be rewritten.
#
# So: take the merge-base against every candidate ref and keep the descendant-most
# one. Whichever ref is fresher, the latest commit the branch shares with any
# spelling of the trunk IS where it forked off.
resolve_fork_point() {
    local names="$1" name ref base best="" best_ref=""
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        for ref in "origin/$name" "$name"; do
            is_ref "$ref" || continue
            base="$(git merge-base "$ref" HEAD 2>/dev/null)" || continue
            [ -n "$base" ] || continue
            # Strictly descendant-most; on a tie the earlier (more authoritative)
            # ref keeps the label, so an up-to-date local trunk doesn't shadow
            # origin/<trunk> in the range summary.
            if [ -z "$best" ] \
                || { [ "$best" != "$base" ] \
                    && git merge-base --is-ancestor "$best" "$base" 2>/dev/null; }; then
                best="$base"; best_ref="$ref"
            fi
        done
    done <<EOF
$names
EOF
    [ -n "$best" ] || return 1
    printf '%s\t%s\n' "$best" "$best_ref"
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

    local names branch fp base base_ref
    names="$(trunk_names | awk 'NF && !seen[$0]++')"
    branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"

    # Feature branch: the whole branch, based at its fork point off the trunk.
    # Requires a resolvable trunk that isn't the branch we're on, and a fork point
    # that isn't HEAD itself (a branch holding nothing of its own has no branch
    # diff to show) — any of those missing falls through to the trunk arm rather
    # than passing a ref that doesn't exist or an empty range.
    if [ -n "$names" ] && ! printf '%s\n' "$names" | grep -qxF -- "$branch" \
        && fp="$(resolve_fork_point "$names")"; then
        base="${fp%%$'\t'*}"
        base_ref="${fp##*$'\t'}"
        if [ "$base" != "$(git rev-parse HEAD)" ]; then
            emit_arg "$base"
            emit_arg "--untracked"
            if is_dirty; then
                emit_range "$base_ref..$branch branch diff + uncommitted (fork point $base)"
            else
                emit_range "$base_ref..$branch full branch diff (fork point $base)"
            fi
            return
        fi
    fi

    # Trunk (or no resolvable trunk): dirty → HEAD..worktree, clean → last commit.
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
