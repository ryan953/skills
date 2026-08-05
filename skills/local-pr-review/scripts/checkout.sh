#!/usr/bin/env bash
# checkout.sh — get the code under review onto disk without disturbing whatever
# the user was in the middle of.
#
# Three cases, in order of how little they cost:
#   1. Already on the head ref -> use $PWD. No worktree, no fetch, and crucially
#      no risk of reviewing a stale copy of my own uncommitted work.
#   2. A worktree for this ref already exists -> reuse it (and fast-forward it).
#   3. Otherwise -> add one under the repo's worktree dir.
#
# Idempotent by design: the iterate loop calls this repeatedly and must land in
# the same place every time.
#
# Usage:
#   checkout.sh --ref <branch> [--pr <n>] [--repo owner/name] [--dir <path>]
# Output: WORKTREE, MODE (cwd|reused|created), REF, HEAD_SHA

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

REF="" PR="" REPO="" DIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --ref) REF="$2"; shift 2 ;;
        --pr) PR="$2"; shift 2 ;;
        --repo) REPO="$2"; shift 2 ;;
        --dir) DIR="$2"; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done

git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"
CURRENT="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"
REF="${REF:-$CURRENT}"

# Case 1: this checkout is already the thing under review.
if [ "$REF" = "$CURRENT" ]; then
    emit WORKTREE "$PWD"
    emit MODE     cwd
    emit REF      "$REF"
    emit HEAD_SHA "$(git rev-parse HEAD)"
    exit 0
fi

TOPLEVEL="$(git rev-parse --show-toplevel)"
DIR="${DIR:-$TOPLEVEL/.claude/worktrees/$(slugify "$REF")}"

# Case 2: an existing worktree for this ref, wherever it lives. `git worktree
# list --porcelain` is the only reliable source — a directory that looks right
# may be a leftover git doesn't know about.
EXISTING="$(git worktree list --porcelain \
    | awk -v r="refs/heads/$REF" '/^worktree /{w=substr($0,10)} /^branch /{if (substr($0,8)==r) print w}' \
    | head -1)"

if [ -n "$EXISTING" ] && [ -d "$EXISTING" ]; then
    emit WORKTREE "$EXISTING"
    emit MODE     reused
    emit REF      "$REF"
    emit HEAD_SHA "$(git -C "$EXISTING" rev-parse HEAD)"
    exit 0
fi

# Case 3: create it. Fetch first so a PR head that only exists on the remote
# resolves; `gh pr checkout` isn't used because it would move *this* checkout.
if [ -n "$PR" ]; then
    git fetch origin "pull/$PR/head:refs/lpr/pr-$PR" --force --quiet 2>/dev/null || true
fi
git fetch origin "$REF" --quiet 2>/dev/null || true

START=""
for cand in "$REF" "origin/$REF" "refs/lpr/pr-${PR:-none}"; do
    if git rev-parse --verify --quiet "$cand^{commit}" >/dev/null 2>&1; then
        START="$cand"; break
    fi
done
[ -n "$START" ] || die "cannot resolve ref '$REF' locally or on origin"

mkdir -p "${DIR%/*}"
if git show-ref --verify --quiet "refs/heads/$REF"; then
    git worktree add "$DIR" "$REF" --quiet
else
    git worktree add "$DIR" -b "$REF" "$START" --quiet
fi

emit WORKTREE "$DIR"
emit MODE     created
emit REF      "$REF"
emit HEAD_SHA "$(git -C "$DIR" rev-parse HEAD)"
