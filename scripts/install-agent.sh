#!/bin/bash
# Install a launchd agent that runs Downpour automatically on a schedule.
#
# Usage:
#   scripts/install-agent.sh [--app <path-to-.app>] [--hour H] [--minute M]
#   scripts/install-agent.sh --interval <seconds>   # run every N seconds instead
#
# Defaults: daily at 02:00, using /Applications/Downpour.app if present,
# otherwise the repo's dist/Downpour.app.
set -euo pipefail

LABEL="dev.vstack.downpour"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/Downpour"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_APP="$SCRIPT_DIR/../dist/Downpour.app"

APP=""
HOUR=2
MINUTE=0
INTERVAL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="$2"; shift 2;;
    --hour) HOUR="$2"; shift 2;;
    --minute) MINUTE="$2"; shift 2;;
    --interval) INTERVAL="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

if [[ -z "$APP" ]]; then
  if [[ -d "/Applications/Downpour.app" ]]; then
    APP="/Applications/Downpour.app"
  elif [[ -d "$REPO_APP" ]]; then
    APP="$(cd "$REPO_APP" && pwd)"
  else
    echo "error: no app found. Build it first (make app) or pass --app <path>." >&2
    exit 1
  fi
fi

BIN="$APP/Contents/MacOS/DownpourApp"
if [[ ! -x "$BIN" ]]; then
  echo "error: executable not found at $BIN" >&2
  exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents" "$LOG_DIR"

if [[ -n "$INTERVAL" ]]; then
  SCHEDULE="    <key>StartInterval</key>
    <integer>$INTERVAL</integer>"
  HUMAN="every $INTERVAL seconds"
else
  SCHEDULE="    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key><integer>$HOUR</integer>
        <key>Minute</key><integer>$MINUTE</integer>
    </dict>"
  HUMAN="daily at $(printf '%02d:%02d' "$HOUR" "$MINUTE")"
fi

cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
        <string>--backup</string>
    </array>
$SCHEDULE
    <key>RunAtLoad</key>
    <false/>
    <key>ProcessType</key>
    <string>Background</string>
    <key>LowPriorityIO</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/launchd.out.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/launchd.err.log</string>
</dict>
</plist>
PLIST_EOF

# Reload.
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo "Installed launchd agent '$LABEL' — runs $HUMAN."
echo "  App:   $APP"
echo "  Plist: $PLIST"
echo "  Logs:  $LOG_DIR/"
echo
echo "Run once now to test:  launchctl start $LABEL"
echo "Remove with:           scripts/uninstall-agent.sh"
