#!/usr/bin/env bash
# Install (or refresh) the daily launchd job for scripts/mac-backup.sh.
# A run missed while the Mac slept starts after wake.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LABEL=com.memohub.backup
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
HOUR="${1:-13}"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/.memohub"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$REPO/scripts/mac-backup.sh</string></array>
  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>$HOUR</integer><key>Minute</key><integer>0</integer></dict>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>/opt/homebrew/bin:/opt/homebrew/opt/libpq/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StandardOutPath</key><string>$HOME/.memohub/backup.log</string>
  <key>StandardErrorPath</key><string>$HOME/.memohub/backup.log</string>
</dict></plist>
PL
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed $LABEL, daily at $HOUR:00 → $HOME/.memohub/backup.log"
