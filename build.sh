#!/bin/zsh
# Builds Onyx.app with the Command Line Tools (no Xcode needed). Usage: ./build.sh [dmg]
set -e
cd "$(dirname "$0")"
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
APP=build/Onyx.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -sdk "$SDK" -target arm64-apple-macosx26.0 -swift-version 5 -O \
  -o "$APP/Contents/MacOS/Onyx" Sources/*.swift
cp Resources/Info.plist "$APP/Contents/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Sign with a stable local identity if one exists, so Accessibility grants survive rebuilds.
# (Ad-hoc signatures change every build, and macOS then treats Onyx as a new app.)
IDENTITY="Onyx Local Signing"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
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
fi
