#!/bin/zsh
# Builds Onyx.app with the Command Line Tools (no Xcode needed). Usage: ./build.sh [dmg [notarize]]
# Notarized builds (see docs/Notarizing.md): ONYX_SIGN_ID="Developer ID Application: Name (TEAMID)" ./build.sh dmg notarize
set -e
cd "$(dirname "$0")"
SDK=${ONYX_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}   # ONYX_SDK: another SDK (the cloud test machines)
# Put together and signed in a temporary folder, then swapped in at the end, so build/Onyx.app is never half-built
# (an Onyx that starts while it's building would run unsigned, with none of its settings).
OUT=build/Onyx.app; WORK=$(mktemp -d); APP="$WORK/Onyx.app"
mkdir -p build "$APP/Contents/MacOS" "$APP/Contents/Resources"
# One app for Apple silicon and Intel Macs (each runs its own half), from macOS 15.4 on. Apple's on-device AI framework only
# exists on macOS 26, so it's linked weakly and Onyx still opens without it. ONYX_ARM_ONLY=1 skips Intel for a quicker test build.
ARCHS=(arm64 x86_64); [ -n "$ONYX_ARM_ONLY" ] && ARCHS=(arm64)
PIDS=(); BINS=()
for A in $ARCHS; do
  # Whole-module: optimized across files (faster, smaller), compiled on several threads; unused code dropped when linking.
  swiftc -sdk "$SDK" -target $A-apple-macosx15.4 -swift-version 5 -O -wmo -num-threads 6 -Xlinker -dead_strip -Xlinker -weak_framework -Xlinker FoundationModels \
    -o "$WORK/Onyx-$A" Sources/*.swift &
  PIDS+=($!); BINS+=("$WORK/Onyx-$A")
done
for P in $PIDS; do wait $P; done
lipo -create $BINS -output "$APP/Contents/MacOS/Onyx"
# (Signing happens below, after this, so the stripped binary is the one that gets signed.)
# The app ships without its symbol names (less than half the size); this copy keeps them, to read crash reports with atos.
cp "$APP/Contents/MacOS/Onyx" "build/Onyx-$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist).symbols" && strip -x "$APP/Contents/MacOS/Onyx" || { echo "strip failed"; exit 1; }
cp Resources/Info.plist "$APP/Contents/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp Resources/*.gif "$APP/Contents/Resources/" 2>/dev/null || true
cp CHANGELOG.md "$APP/Contents/Resources/"   # What's New reads the new version's notes from it
# Sign with a stable local identity if one exists, so Accessibility grants survive rebuilds.
# (Ad-hoc signatures change every build, and macOS then treats Onyx as a new app.)
IDENTITY="${ONYX_SIGN_ID:-Onyx Local Signing}"
xattr -cr "$APP"   # iCloud Drive tags files with Finder info, which codesign refuses
if [ -n "$ONYX_SIGN_ID" ]; then
  # Developer ID: Apple's hardened runtime (needed for notarization), with the permissions Onyx asks for.
  codesign --force --deep --options runtime --timestamp --entitlements Resources/Onyx.entitlements --sign "$IDENTITY" "$APP"
elif security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  codesign --force --deep --sign "$IDENTITY" "$APP"
else
  codesign --force --deep --sign - "$APP"
fi
rm -rf "$OUT"; ditto --noextattr "$APP" "$OUT"; rm -rf "$WORK"; APP="$OUT"
echo "Built $APP"
if [ "$1" = "dmg" ]; then
  # Staged outside the project: iCloud Drive tags files there with Finder info, which breaks the signature check.
  STAGE=$(mktemp -d); rm -f build/Onyx.dmg; mkdir -p "$STAGE/dmg"
  ditto --noextattr --norsrc "$APP" "$STAGE/dmg/Onyx.app"; ln -s /Applications "$STAGE/dmg/Applications"
  codesign -v --strict --deep "$STAGE/dmg/Onyx.app"
  hdiutil create -volname Onyx -srcfolder "$STAGE/dmg" -ov -format UDZO "$STAGE/Onyx.dmg" >/dev/null
  ditto --noextattr "$STAGE/Onyx.dmg" build/Onyx.dmg; rm -rf "$STAGE"
  echo "Built build/Onyx.dmg"
  if [ "$2" = "notarize" ]; then
    [ -n "$ONYX_SIGN_ID" ] || { echo "Set ONYX_SIGN_ID to your Developer ID Application identity first."; exit 1; }
    codesign --sign "$IDENTITY" --timestamp build/Onyx.dmg
    xcrun notarytool submit build/Onyx.dmg --keychain-profile "${ONYX_NOTARY_PROFILE:-onyx-notary}" --wait
    xcrun stapler staple build/Onyx.dmg
    echo "Notarized build/Onyx.dmg"
  fi
fi
