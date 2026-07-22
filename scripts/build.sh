#!/bin/bash
# Builds TempControl.app + the helper binary into ./build (no Xcode project needed).
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname -m)" != "arm64" ]]; then
    echo "TempControl requires an Apple Silicon Mac." >&2
    exit 1
fi

echo "==> swift build -c release"
swift build -c release

mkdir -p build
APP="build/TempControl.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/TempControl "$APP/Contents/MacOS/TempControl"
cp .build/release/TempControlHelper build/tempcontrol-helper
cp resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [[ ! -f build/AppIcon.icns ]]; then
    echo "==> generating icon"
    swift scripts/makeicon.swift build
    iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signing: fine for a locally built app (no Gatekeeper quarantine on
# files you build yourself).
codesign --force -s - build/tempcontrol-helper
codesign --force -s - "$APP"

echo "==> built $APP and build/tempcontrol-helper"
