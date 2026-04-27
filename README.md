# HA Im Home — Mac Daemon

A lightweight macOS daemon that acts as a BLE (Bluetooth Low Energy) bridge between your iPhone and Home Assistant.

## How It Works
```
iPhone (HA Im Home app)
└─ detects arrival via GPS + elevator pressure drop
└─ connects via BLE
└─ Mac Mini daemon verifies HMAC signature
└─ notifies Home Assistant webhook
```

## Requirements

- macOS 12+
- Mac with Bluetooth (always-on, e.g. Mac Mini)
- Home Assistant with [ha-im-home](https://github.com/ab19117814/ha-im-home) integration installed
- HA Im Home iOS app (https://github.com/ab19117814/ha-im-home-ios)

## Installation

```bash
# 1. Clone the repo
git clone https://github.com/yourusername/ha-im-home-daemon
cd ha-im-home-daemon

# 2. Build
swiftc imhomed.swift -o imhomed
# or open in Xcode and Archive

# 3. Install
chmod +x install.sh uninstall.sh
sudo ./install.sh
```

The installer will:
- Ask for your HA URL and token
- Copy the binary to `/Library/Application Support/ImHome/`
- Register a LaunchAgent so the daemon starts automatically on login

## Uninstall

```bash
sudo ./uninstall.sh
```

## Logs

```bash
tail -f /tmp/imhome.log
```

## Security

- HMAC-SHA256 authentication with per-user secrets
- 30-second timestamp window to prevent replay attacks
- Nonce tracking to prevent duplicate requests
- Secrets stored in Home Assistant, never on the Mac

## License

MIT
