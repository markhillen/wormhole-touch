#!/bin/bash
set -euo pipefail
LABEL=io.github.wormhole-touch.PortalTouch
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf /Applications/PortalTouch.app
echo "Removed. You can also remove PortalTouch from System Settings > Privacy & Security > Accessibility."
