#!/bin/bash
# Removes everything install.sh put on the system. Fans return to macOS
# automatic control the moment the helper stops.
set -euo pipefail

HELPER_LABEL="com.tempcontrol.helper"

echo "==> removing TempControl (you may be asked for your password)"
osascript -e 'quit app "TempControl"' 2>/dev/null || true
sudo launchctl bootout "system/${HELPER_LABEL}" 2>/dev/null || true
# Put battery charging / MagSafe LED SMC keys back to macOS defaults BEFORE
# deleting the helper — otherwise a charge limit could outlive the app.
sudo "/Library/PrivilegedHelperTools/${HELPER_LABEL}" --reset-battery 2>/dev/null || true
sudo rm -f "/Library/LaunchDaemons/${HELPER_LABEL}.plist"
sudo rm -f "/Library/PrivilegedHelperTools/${HELPER_LABEL}"
sudo rm -rf "/Library/Application Support/TempControl"
sudo rm -rf /Applications/TempControl.app
echo "==> done. Fans and battery charging are back under macOS control."
