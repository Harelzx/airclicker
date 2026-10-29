#!/bin/zsh
# Builds build/AirClicker.app for this Mac.
#
# Signing: by default the app is signed ad hoc ("-"), which needs no Apple account.
# macOS then asks for Accessibility again after every rebuild. To keep the grant across
# rebuilds, sign with your own identity: put SIGN_IDENTITY="Apple Development: ..." in
# .env.local (gitignored) or export it. `security find-identity -p codesigning -v` lists yours.
set -euo pipefail
cd "$(dirname "$0")"

[[ -f .env.local ]] && source .env.local
APP=build/AirClicker.app
IDENTITY="${SIGN_IDENTITY:--}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp assets/icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
swiftc -swift-version 5 -O -target "$(uname -m)-apple-macos14.0" \
    Sources/AirClicker/main.swift -o "$APP/Contents/MacOS/AirClicker"
codesign --force --sign "$IDENTITY" "$APP"
echo "Built $APP"
