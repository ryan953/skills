#!/usr/bin/env bash
set -euo pipefail

# Remove the worktree-janitor LaunchAgent. Leaves logs and the undo log alone.

LABEL="${1:-com.ryan953.worktree-janitor}"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null \
  || launchctl unload "$PLIST" 2>/dev/null \
  || true
rm -f "$PLIST"

echo "removed $LABEL"
echo "kept: ~/.local/worktree-janitor/logs and ~/.claude/worktree-janitor.log"
