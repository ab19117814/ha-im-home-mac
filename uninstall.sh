#!/bin/bash
AGENT_ID="com.imhome.agent"
PLIST_PATH="/Library/LaunchAgents/${AGENT_ID}.plist"

[[ $EUID -ne 0 ]] && echo "❌  sudo ./uninstall.sh" && exit 1

launchctl unload "$PLIST_PATH" 2>/dev/null && echo "⏹  Agent stopped"
rm -f "$PLIST_PATH"
rm -rf "/Library/Application Support/ImHome"
rm -f /tmp/imhome.log

echo "✅  Uninstalled"
