#!/usr/bin/env bash
# Builds an ad hoc signed Release app and packages it as dist/NetPulse-<version>.dmg.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || { echo "xcodegen not found: brew install xcodegen" >&2; exit 1; }
xcodegen generate --quiet

# Signing is overridden on the command line, so a team set in Config/Local.xcconfig never ends up in a release.
xcodebuild -project NetPulse.xcodeproj -scheme NetPulse -configuration Release \
	-derivedDataPath .build/release-adhoc CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build -quiet

APP=.build/release-adhoc/Build/Products/Release/NetPulse.app
codesign --verify --strict "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/NetPulse.app"
ln -s /Applications "$STAGE/Applications"

mkdir -p dist
DMG="dist/NetPulse-$VERSION.dmg"
hdiutil create -volname NetPulse -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null
echo "Built $DMG ($(lipo -archs "$APP/Contents/MacOS/NetPulse"))"
shasum -a 256 "$DMG"
