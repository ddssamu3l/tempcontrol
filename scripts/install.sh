#!/bin/bash
# Builds and installs TempControl:
#   - TempControl.app             -> /Applications
#   - root helper (fan control)   -> /Library/PrivilegedHelperTools
#   - helper LaunchDaemon         -> /Library/LaunchDaemons
# The single sudo prompt is what authorizes fan control + powermetrics.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build.sh

HELPER_LABEL="com.tempcontrol.helper"
HELPER_DST="/Library/PrivilegedHelperTools/${HELPER_LABEL}"
DAEMON_PLIST="/Library/LaunchDaemons/${HELPER_LABEL}.plist"

echo "==> installing (you will be asked for your password once)"
sudo -v

# Stop anything already running.
sudo launchctl bootout "system/${HELPER_LABEL}" 2>/dev/null || true
osascript -e 'quit app "TempControl"' 2>/dev/null || true

echo "==> /Applications/TempControl.app"
sudo rm -rf /Applications/TempControl.app
sudo cp -R build/TempControl.app /Applications/

echo "==> ${HELPER_DST}"
sudo mkdir -p /Library/PrivilegedHelperTools
sudo cp build/tempcontrol-helper "${HELPER_DST}"
sudo chown root:wheel "${HELPER_DST}"
sudo chmod 755 "${HELPER_DST}"

echo "==> ${DAEMON_PLIST}"
sudo cp resources/${HELPER_LABEL}.plist "${DAEMON_PLIST}"
sudo chown root:wheel "${DAEMON_PLIST}"
sudo chmod 644 "${DAEMON_PLIST}"
sudo launchctl bootstrap system "${DAEMON_PLIST}"

echo "==> launching"
open /Applications/TempControl.app

cat <<'EOF'

Installed. TempControl is now in your menu bar (thermometer icon).
 - Click it for the dashboard and the temperature dial.
 - Toggle [ LOGIN: ON ] in the app footer to start it at login.
 - Uninstall any time with: ./scripts/uninstall.sh
EOF
