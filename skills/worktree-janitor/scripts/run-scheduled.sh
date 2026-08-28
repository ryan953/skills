#!/usr/bin/env bash
set -uo pipefail

# launchd entry point for worktree-janitor. Keep this thin: it exists to give
# janitor.sh the environment a LaunchAgent does not provide.
#
# Installed by install/install.sh, which points the LaunchAgent at this file.

# LaunchAgents run with a minimal PATH; git/gh/jq live in Homebrew.
export PATH="$HOME/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
JANITOR="$HERE/janitor.sh"

# gh needs a token in a non-login context, where the keyring is not unlocked
# the way it is in a terminal.
if [ -z "${GITHUB_TOKEN:-}" ] && command -v gh >/dev/null 2>&1; then
  GITHUB_TOKEN="$(gh auth token 2>/dev/null)" && export GITHUB_TOKEN
fi

if [ ! -f "$JANITOR" ]; then
  echo "$(date -u +%FT%TZ) ERROR: $JANITOR not found" >&2
  exit 1
fi

echo "### $(date -u +%FT%TZ) worktree-janitor starting ($HERE)"
# Invoked through bash on purpose: dotagents materializes skill files by copy,
# and the executable bit is not something to depend on.
bash "$JANITOR" --apply "$@"
status=$?
echo "### $(date -u +%FT%TZ) finished (exit $status)"
exit "$status"
