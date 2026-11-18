#!/bin/bash
# Installs PortalTouch.app into /Applications and starts it at login (LaunchAgent).
set -euo pipefail
cd "$(dirname "$0")"
LABEL=io.github.wormhole-touch.PortalTouch
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
[ -d build/PortalTouch.app ] || ./build.sh
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -rf /Applications/PortalTouch.app
ditto build/PortalTouch.app /Applications/PortalTouch.app
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array><string>/Applications/PortalTouch.app/Contents/MacOS/PortalTouch</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>ProcessType</key><string>Interactive</string>
<key>StandardErrorPath</key><string>$HOME/Library/Logs/PortalTouch.log</string>
</dict></plist>
PLIST
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed. Allow PortalTouch in System Settings > Privacy & Security > Accessibility,"
echo "and allow Local Network access if macOS asks. Log: ~/Library/Logs/PortalTouch.log"
