#!/usr/bin/env bash
set -euo pipefail

# Install the worktree-janitor LaunchAgent.
#
# dotagents distributes the skill directory, but it does not manage macOS
# LaunchAgents or ~/bin. This script bridges that gap, and is safe to re-run.
#
#   bash install/install.sh            # hourly at :47
#   bash install/install.sh --minute 12
#   bash install/install.sh --dry-run  # print the plist, change nothing

LABEL="com.ryan953.worktree-janitor"
MINUTE=47
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --minute)  MINUTE="$2"; shift ;;
    --label)   LABEL="$2"; shift ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '3,12p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

case "$(uname -s)" in
  Darwin) ;;
  *) echo "LaunchAgents are macOS-only; nothing to install on $(uname -s)." >&2; exit 0 ;;
esac
if ! [[ "$MINUTE" =~ ^[0-9]+$ ]] || [ "$MINUTE" -gt 59 ]; then
  echo "--minute must be 0-59" >&2; exit 2
fi

# Resolve the skill root from this script's own location, so the LaunchAgent
# points at whichever copy is actually installed - the dotagents-managed one
# under ~/.agents/skills, or a development checkout.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_ROOT="$(cd "$HERE/.." && pwd -P)"
RUNNER="$SKILL_ROOT/scripts/run-scheduled.sh"
TEMPLATE="$HERE/${LABEL}.plist.template"
LOG_DIR="$HOME/.local/worktree-janitor/logs"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"

[ -f "$RUNNER" ]   || { echo "missing runner: $RUNNER" >&2; exit 1; }
[ -f "$TEMPLATE" ] || { echo "missing template: $TEMPLATE" >&2; exit 1; }
for bin in git gh jq; do
  command -v "$bin" >/dev/null || echo "warning: '$bin' is not on PATH; the job will fail until it is" >&2
done

rendered=$(sed \
  -e "s|__LABEL__|$LABEL|g" \
  -e "s|__RUNNER__|$RUNNER|g" \
  -e "s|__LOG_DIR__|$LOG_DIR|g" \
  -e "s|__MINUTE__|$MINUTE|g" "$TEMPLATE")

if [ "$DRY_RUN" -eq 1 ]; then
  printf '%s\n' "$rendered"
  echo "# would write: $PLIST" >&2
  exit 0
fi

mkdir -p "$LOG_DIR" "$HOME/Library/LaunchAgents"
printf '%s\n' "$rendered" >"$PLIST"
plutil -lint "$PLIST" >/dev/null

# Replace any previous registration. bootout/bootstrap is the modern form;
# fall back to unload/load on older macOS.
if launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null; then :; else
  launchctl unload "$PLIST" 2>/dev/null || true
fi
if ! launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null; then
  launchctl load "$PLIST" 2>/dev/null || { echo "failed to register $LABEL" >&2; exit 1; }
fi

echo "installed $LABEL"
echo "  runs    hourly at :$MINUTE"
echo "  runner  $RUNNER"
echo "  logs    $LOG_DIR/janitor.{out,err}.log"
echo "  plist   $PLIST"
echo
echo "Run once now:  launchctl kickstart -k gui/$(id -u)/$LABEL"
echo "Remove it:     bash $HERE/uninstall.sh"
