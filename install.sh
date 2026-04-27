#!/bin/bash
set -e

AGENT_ID="com.imhome.agent"
APP_DIR="/Library/Application Support/ImHome"
PLIST_PATH="/Library/LaunchAgents/${AGENT_ID}.plist"
BINARY_NAME="imhomed"

if [[ $EUID -ne 0 ]]; then
    echo "❌  Run as root: sudo ./install.sh"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINARY_SRC="$SCRIPT_DIR/$BINARY_NAME"

if [[ ! -f "$BINARY_SRC" ]]; then
    echo "❌  Binary not found: $BINARY_SRC"
    echo "    First compile: swiftc imhomed.swift -o imhomed"
    exit 1
fi

if launchctl list | grep -q "$AGENT_ID"; then
    echo "⏹  Stop old agent…"
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
fi

echo "📁  Creating $APP_DIR"
mkdir -p "$APP_DIR"
cp "$BINARY_SRC" "$APP_DIR/$BINARY_NAME"
chmod 755 "$APP_DIR/$BINARY_NAME"
chown root:wheel "$APP_DIR/$BINARY_NAME"


CONFIG_PATH="$APP_DIR/imhome.json"

if [[ ! -f "$CONFIG_PATH" ]] || grep -q "YOUR TOKEN HERE" "$CONFIG_PATH"; then
    echo ""
    echo "📝  Setup:"
    read -p "   HA URL (press enter for default http://homeassistant.local:8123): " HA_URL
    HA_URL="${HA_URL:-http://homeassistant.local:8123}"
    read -p "   HA Token: " HA_TOKEN
    
    cat > "$CONFIG_PATH" <<EOF
{
  "ha_url":   "${HA_URL}",
  "ha_token": "${HA_TOKEN}"
}
EOF
    chmod 644 "$CONFIG_PATH"
    chown root:staff "$CONFIG_PATH"
    echo "✅  Saved"
fi

echo "📄  Creating $PLIST_PATH"
cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${AGENT_ID}</string>

    <key>ProgramArguments</key>
    <array>
        <string>${APP_DIR}/${BINARY_NAME}</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <key>StandardOutPath</key>
    <string>/tmp/imhome.log</string>

    <key>StandardErrorPath</key>
    <string>/tmp/imhome.log</string>

    <key>ThrottleInterval</key>
    <integer>10</integer>
</dict>
</plist>
EOF

chmod 644 "$PLIST_PATH"
chown root:wheel "$PLIST_PATH"

echo "🚀  Starting…"
sudo -u "$(logname)" launchctl load "$PLIST_PATH"

echo ""
echo "✅  Ready!"
echo ""
echo "Useful commands:"
echo "  Status:    sudo launchctl list | grep imhome"
echo "  Logs:      tail -f /tmp/imhome.log"
echo "  Stop:      launchctl unload $PLIST_PATH"
echo "  Start:     launchctl load $PLIST_PATH"
echo "  Remove:   sudo ./uninstall.sh"
