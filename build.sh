#!/bin/zsh
# Builds ScufBridge.app.
#
#   ./build.sh              unsigned-entitlement build (use with --dry-run)
#   ./build.sh profile.provisionprofile
#                           signed build with the HID virtual device entitlement
set -euo pipefail
cd "${0:A:h}"

TEAM_ID="${TEAM_ID:-ML3YMTE3UC}"
BUNDLE_ID="${BUNDLE_ID:-com.eamonbauman.scuf-bridge}"
IDENTITY="${IDENTITY:-Apple Development}"
PROFILE="${1:-}"

APP=build/ScufBridge.app
rm -rf build
mkdir -p "$APP/Contents/MacOS"

swiftc -O Sources/main.swift -o "$APP/Contents/MacOS/scuf-bridge"
sed "s/__BUNDLE_ID__/$BUNDLE_ID/" Info.plist > "$APP/Contents/Info.plist"

if [[ -n "$PROFILE" ]]; then
    cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
    sed -e "s/__TEAM_ID__/$TEAM_ID/g" -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" \
        scuf-bridge.entitlements > build/entitlements.plist
    codesign --force --sign "$IDENTITY" --entitlements build/entitlements.plist \
        --options runtime "$APP"
    echo "Signed with entitlements: $APP"
else
    codesign --force --sign "$IDENTITY" "$APP"
    echo "Signed without entitlements (dry-run only): $APP"
fi
