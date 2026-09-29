#!/bin/zsh
# Builds Onyx.app with the Command Line Tools (no Xcode needed). Usage: ./build.sh [dmg [notarize]]
# Notarized builds (see docs/Notarizing.md): ONYX_SIGN_ID="Developer ID Application: Name (TEAMID)" ./build.sh dmg notarize
set -e
cd "$(dirname "$0")"
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
APP=build/Onyx.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -sdk "$SDK" -target arm64-apple-macosx26.0 -swift-version 5 -O \
  -o "$APP/Contents/MacOS/Onyx" Sources/*.swift
cp Resources/Info.plist "$APP/Contents/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp Resources/*.gif "$APP/Contents/Resources/" 2>/dev/null || true
cp CHANGELOG.md "$APP/Contents/Resources/"   # What's New reads the new version's notes from it
# Sign with a stable local identity if one exists, so Accessibility grants survive rebuilds.
# (Ad-hoc signatures change every build, and macOS then treats Onyx as a new app.)
IDENTITY="${ONYX_SIGN_ID:-Onyx Local Signing}"
if [ -n "$ONYX_SIGN_ID" ]; then
  # Developer ID: Apple's hardened runtime (needed for notarization), with the permissions Onyx asks for.
  codesign --force --deep --options runtime --timestamp --entitlements Resources/Onyx.entitlements --sign "$IDENTITY" "$APP"
elif security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  codesign --force --deep --sign "$IDENTITY" "$APP"
else
  codesign --force --deep --sign - "$APP"
fi
echo "Built $APP"
if [ "$1" = "dmg" ]; then
  rm -rf build/dmg build/Onyx.dmg; mkdir -p build/dmg
  cp -R "$APP" build/dmg/; ln -s /Applications build/dmg/Applications
  hdiutil create -volname Onyx -srcfolder build/dmg -ov -format UDZO build/Onyx.dmg >/dev/null
  rm -rf build/dmg
  echo "Built build/Onyx.dmg"
  if [ "$2" = "notarize" ]; then
    [ -n "$ONYX_SIGN_ID" ] || { echo "Set ONYX_SIGN_ID to your Developer ID Application identity first."; exit 1; }
    codesign --sign "$IDENTITY" --timestamp build/Onyx.dmg
    xcrun notarytool submit build/Onyx.dmg --keychain-profile "${ONYX_NOTARY_PROFILE:-onyx-notary}" --wait
    xcrun stapler staple build/Onyx.dmg
    echo "Notarized build/Onyx.dmg"
  fi
fi
