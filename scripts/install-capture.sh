#!/usr/bin/env bash
# Install (or refresh) the launchd job for scripts/capture.py: every 10 minutes and at login.
# Needs ~/.memohub/capture.conf (DEVICE, TARGET, MODE, PROJECTS); see the header of capture.py.
#   install-capture.sh            install
#   install-capture.sh --remove   stop and remove the job (state in ~/.memohub/capture stays)
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LABEL=com.memohub.capture
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
if [ "${1:-}" = --remove ]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"; echo "removed $LABEL"; exit 0
fi
[ -f "$HOME/.memohub/capture.conf" ] || { echo "create ~/.memohub/capture.conf first (see scripts/capture.py)" >&2; exit 1; }
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/usr/bin/python3</string><string>-I</string><string>$REPO/scripts/capture.py</string><string>run</string>
  </array>
  <key>StartInterval</key><integer>600</integer>
  <key>RunAtLoad</key><true/>
  <key>LowPriorityIO</key><true/>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StandardOutPath</key><string>/dev/null</string>
  <key>StandardErrorPath</key><string>$HOME/.memohub/capture.err</string>
</dict></plist>
PL
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed $LABEL, every 10 min → $HOME/.memohub/capture.log"
