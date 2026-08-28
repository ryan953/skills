#!/usr/bin/env bash
# worktree-janitor - remove linked git worktrees whose work is safely on GitHub.
#
# Safe by default: prints a plan and changes nothing unless --apply is given.
# Every removal is recorded with a restore command in the log.
set -uo pipefail

ROOT="${WORKTREE_JANITOR_ROOT:-$HOME/code}"
LOG="${WORKTREE_JANITOR_LOG:-$HOME/.claude/worktree-janitor.log}"
LOCK="${WORKTREE_JANITOR_LOCK:-$HOME/.claude/worktree-janitor.lock}"
LOCK_TTL_MIN=55
APPLY=0
KEEP_BRANCH=0
IGNORE_CWD=0
JSON=0

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)       APPLY=1 ;;
    --dry-run)     APPLY=0 ;;
    --keep-branch) KEEP_BRANCH=1 ;;
    --ignore-cwd)  IGNORE_CWD=1 ;;
    --json)        JSON=1 ;;
    --root)        ROOT="$2"; shift ;;
    -h|--help)     sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

for bin in git gh jq; do
  command -v "$bin" >/dev/null || { echo "missing required tool: $bin" >&2; exit 2; }
done
mkdir -p "$(dirname "$LOG")"

# --- mutual exclusion -------------------------------------------------------
# Local scheduled tasks share one filesystem, so an atomic mkdir is a real lock.
# The lease stops a crashed run from holding it forever.
if ! mkdir "$LOCK" 2>/dev/null; then
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +$LOCK_TTL_MIN 2>/dev/null)" ]; then
    echo "note: breaking stale lock (older than ${LOCK_TTL_MIN}m)" >&2
    rm -rf "$LOCK"; mkdir "$LOCK" 2>/dev/null || { echo "lock race lost; exiting" >&2; exit 0; }
  else
    echo "another janitor run holds the lock; exiting" >&2
    exit 0
  fi
fi
trap 'rm -rf "$LOCK"' EXIT

RESULTS=()   # status<TAB>repo<TAB>path<TAB>branch<TAB>detail<TAB>size
add() { RESULTS+=("$1	$2	$3	$4	$5	$6"); }

# --- helpers ----------------------------------------------------------------
nwo_of() { # origin URL -> owner/repo, empty when not github.com
  local url; url=$(git -C "$1" remote get-url origin 2>/dev/null) || return 1
  case "$url" in
    git@github.com:*) printf '%s' "${url#git@github.com:}" | sed 's/\.git$//' ;;
    https://github.com/*) printf '%s' "${url#https://github.com/}" | sed 's/\.git$//' ;;
    *) return 1 ;;
  esac
}

# One lsof pass for the whole run: "<path>\t<cmd> (pid N)".
CWD_MAP=$(lsof -d cwd -F pcn 2>/dev/null | awk '
  /^p/{pid=substr($0,2)} /^c/{cmd=substr($0,2)}
  /^n/{print substr($0,2) "\t" cmd " (pid " pid ")"}')

held_by() { # echo the first process whose cwd is this dir, else nothing
  [ "$IGNORE_CWD" -eq 1 ] && return 1
  printf '%s\n' "$CWD_MAP" | awk -F'\t' -v T="$1" '$1==T{print $2; exit}'
}

human_size() { du -sh "$1" 2>/dev/null | cut -f1; }

# --- scan -------------------------------------------------------------------
for repo in "$ROOT"/*/; do
  repo="${repo%/}"
  [ -e "$repo/.git" ] || continue
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || continue

  main_wt=$(git -C "$repo" rev-parse --path-format=absolute --show-toplevel 2>/dev/null)
  nwo=$(nwo_of "$repo") || nwo=""

  # Enumerate worktrees: path, branch, and whether git marked it locked.
  while IFS=$'\t' read -r wt branch locked; do
    [ -n "$wt" ] || continue
    [ "$wt" = "$main_wt" ] && continue          # never touch the primary worktree
    case "$wt" in "$ROOT"/*) ;; *) continue ;; esac

    name="${wt#$ROOT/}"
    if [ "$locked" = "locked" ]; then
      add SKIP "$repo" "$wt" "${branch:--}" "worktree is locked" "-"; continue
    fi
    if [ -z "$branch" ]; then
      add SKIP "$repo" "$wt" "-" "detached HEAD, cannot map to a PR" "-"; continue
    fi

    dirty=$(git -C "$wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    if [ "${dirty:-0}" -gt 0 ]; then
      add SKIP "$repo" "$wt" "$branch" "$dirty uncommitted file(s)" "-"; continue
    fi
    holder=$(held_by "$wt")
    if [ -n "$holder" ]; then
      add SKIP "$repo" "$wt" "$branch" "in use by $holder" "-"; continue
    fi

    head=$(git -C "$wt" rev-parse HEAD 2>/dev/null)
    reason=""; safe=0

    # Route 1: a PR whose head commit is exactly our HEAD.
    if [ -n "$nwo" ]; then
      pr=$(gh pr list --repo "$nwo" --head "$branch" --state all \
             --json number,state,headRefOid --jq 'sort_by(.number)|last' 2>/dev/null)
      if [ -n "$pr" ] && [ "$pr" != "null" ]; then
        pr_num=$(jq -r .number <<<"$pr"); pr_state=$(jq -r .state <<<"$pr")
        pr_oid=$(jq -r .headRefOid <<<"$pr")
        if [ "$pr_oid" = "$head" ]; then
          safe=1; reason="PR #$pr_num $pr_state"
        else
          reason="PR #$pr_num $pr_state but local HEAD differs from PR head"
        fi
      fi
    fi

    # Route 2: no matching PR, but origin already contains every local commit.
    if [ "$safe" -eq 0 ]; then
      if git -C "$wt" rev-parse --verify -q "refs/remotes/origin/$branch" >/dev/null 2>&1 \
         && git -C "$wt" merge-base --is-ancestor HEAD "refs/remotes/origin/$branch" 2>/dev/null; then
        safe=1; reason="pushed to origin/$branch"
      fi
    fi

    if [ "$safe" -eq 0 ]; then
      add SKIP "$repo" "$wt" "$branch" "${reason:-not on GitHub (no PR, not pushed)}" "-"; continue
    fi

    size=$(human_size "$wt")
    if [ "$APPLY" -eq 0 ]; then
      add WOULD-REMOVE "$repo" "$wt" "$branch" "$reason" "$size"; continue
    fi

    # --- remove -------------------------------------------------------------
    restore="git -C '$repo' worktree add --detach '$wt' $head   # branch was: $branch"
    if ! git -C "$repo" worktree remove "$wt" 2>/dev/null; then
      add SKIP "$repo" "$wt" "$branch" "git refused to remove the worktree" "$size"; continue
    fi
    printf '%s\tREMOVED\t%s\t%s\t%s\n\t%s\n' \
      "$(date -u +%FT%TZ)" "$wt" "$branch" "$reason" "$restore" >>"$LOG"

    if [ "$KEEP_BRANCH" -eq 0 ]; then
      # Only if no other worktree still checks this branch out.
      others=$(git -C "$repo" worktree list --porcelain | grep -c "^branch refs/heads/$branch$")
      [ "${others:-0}" -eq 0 ] && git -C "$repo" branch -D "$branch" >/dev/null 2>&1
    fi
    add REMOVED "$repo" "$wt" "$branch" "$reason" "$size"

  done < <(git -C "$repo" worktree list --porcelain 2>/dev/null | awk '
      /^worktree /{ if (p != "") print p "\t" b "\t" l; p=substr($0,10); b=""; l="" }
      /^branch /  { b=substr($0,8); sub(/^refs\/heads\//,"",b) }
      /^locked/   { l="locked" }
      END{ if (p != "") print p "\t" b "\t" l }')
done

# --- report -----------------------------------------------------------------
if [ "$JSON" -eq 1 ]; then
  printf '%s\n' "${RESULTS[@]:-}" | jq -R -s 'split("\n")|map(select(length>0)|split("\t")|
    {status:.[0],repo:.[1],path:.[2],branch:.[3],detail:.[4],size:.[5]})'
  exit 0
fi

removed=0; skipped=0
[ "$APPLY" -eq 1 ] && verb="Removed" || verb="Would remove"
echo "== $verb =="
for r in "${RESULTS[@]:-}"; do
  IFS=$'\t' read -r st repo path br detail size <<<"$r"
  case "$st" in
    REMOVED|WOULD-REMOVE) removed=$((removed+1))
      printf '  %-46s %-8s %s\n' "${path#$ROOT/}" "$size" "$detail" ;;
  esac
done
[ "$removed" -eq 0 ] && echo "  (nothing eligible)"
echo
echo "== Kept =="
for r in "${RESULTS[@]:-}"; do
  IFS=$'\t' read -r st repo path br detail size <<<"$r"
  if [ "$st" = "SKIP" ]; then
    skipped=$((skipped+1)); printf '  %-46s %s\n' "${path#$ROOT/}" "$detail"
  fi
done
[ "$skipped" -eq 0 ] && echo "  (none)"
echo
echo "$verb: $removed   Kept: $skipped"
[ "$APPLY" -eq 1 ] && [ "$removed" -gt 0 ] && echo "Restore commands logged to $LOG"
exit 0
