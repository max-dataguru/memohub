#!/usr/bin/env bash
# Install (or refresh) the nightly launchd job for scripts/distill.py, at 04:00 by default (a run
# missed while the Mac slept starts after wake). Nothing is distilled until a source is allowed:
#   scripts/distill.py allow claude-code
# Config: ~/.memohub/distill.conf (optional, see scripts/distill.py).
#   install-distill.sh [hour]     default 4
#   install-distill.sh --remove
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LABEL=com.memohub.distill
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
if [ "${1:-}" = --remove ]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true; rm -f "$PLIST"; echo "removed $LABEL"; exit 0
fi
HOUR="${1:-4}"
# claude -p needs the claude CLI on PATH; keep the directory it is installed in.
CLAUDE_DIR="$(dirname "$(command -v claude 2>/dev/null || echo /opt/homebrew/bin/claude)")"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/.memohub"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/usr/bin/python3</string><string>-I</string><string>$REPO/scripts/distill.py</string><string>run</string>
  </array>
  <key>StartCalendarInterval</key><dict>
    <key>Hour</key><integer>$HOUR</integer><key>Minute</key><integer>0</integer>
  </dict>
  <key>LowPriorityIO</key><true/>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>$CLAUDE_DIR:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StandardOutPath</key><string>/dev/null</string>
  <key>StandardErrorPath</key><string>$HOME/.memohub/distill.err</string>
</dict></plist>
PL
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed $LABEL, daily at $HOUR:00 → $HOME/.memohub/distill.log"
