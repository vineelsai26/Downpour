#!/bin/bash
# Remove the Downpour launchd agent.
set -euo pipefail

LABEL="dev.vstack.downpour"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [[ -f "$PLIST" ]]; then
  launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  echo "Removed launchd agent '$LABEL'."
else
  echo "No launchd agent installed ($PLIST not found)."
fi
