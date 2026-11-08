#!/usr/bin/env bash
# Install (or refresh) the weekly launchd job for scripts/health.py: Mondays at 10:00 (a run missed
# while the Mac slept starts after wake). The report goes to ~/.memohub/reports/; a notification
# appears only when something needs attention.
#   install-health.sh [hour]     default 10
#   install-health.sh --remove
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LABEL=com.memohub.health
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
if [ "${1:-}" = --remove ]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true; rm -f "$PLIST"; echo "removed $LABEL"; exit 0
fi
HOUR="${1:-10}"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/.memohub/reports"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/usr/bin/python3</string><string>-I</string><string>$REPO/scripts/health.py</string><string>--notify</string>
  </array>
  <key>StartCalendarInterval</key><dict>
    <key>Weekday</key><integer>1</integer><key>Hour</key><integer>$HOUR</integer><key>Minute</key><integer>0</integer>
  </dict>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StandardOutPath</key><string>/dev/null</string>
  <key>StandardErrorPath</key><string>$HOME/.memohub/health.err</string>
</dict></plist>
PL
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed $LABEL, Mondays at $HOUR:00 → $HOME/.memohub/reports/"
