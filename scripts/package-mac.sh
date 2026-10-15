#!/usr/bin/env bash
# macOS packaging: build (universal by default), bundle ffmpeg, ad-hoc sign the whole bundle,
# verify, and make the .dmg. Run from the repository root after scripts/fetch-ffmpeg.sh mac.
# See docs/SIGNING.md for turning on Developer ID signing and notarisation.
set -euo pipefail
VERSION=$(grep '^version:' pubspec.yaml | awk '{print $2}' | cut -d+ -f1)
flutter build macos --release
APP="build/macos/Build/Products/Release/Soundbites.app"
[ -d "$APP" ] || APP=$(ls -d build/macos/Build/Products/Release/*.app | head -1)
mkdir -p "$APP/Contents/Resources/ffmpeg"
cp vendor/ffmpeg/mac/ffmpeg vendor/ffmpeg/mac/ffprobe "$APP/Contents/Resources/ffmpeg/"
cp vendor/ffmpeg/mac/COPYING.LGPLv2.1 vendor/ffmpeg/mac/LICENSE.ffmpeg.md vendor/ffmpeg/mac/COPYING.lame "$APP/Contents/Resources/ffmpeg/" 2>/dev/null || true
chmod +x "$APP/Contents/Resources/ffmpeg/ffmpeg" "$APP/Contents/Resources/ffmpeg/ffprobe"
lipo -info "$APP/Contents/Resources/ffmpeg/ffmpeg"
lipo -info "$APP/Contents/MacOS/Soundbites" || lipo -info "$APP/Contents/MacOS/"*

# Ad-hoc signature ("-"): Apple Silicon refuses unsigned code, and the signature must cover
# everything, including ffmpeg, or the app shows "is damaged". No hardened runtime yet.
IDENTITY="${SIGNING_IDENTITY:--}"
ENT="macos/Runner/Release.entitlements"
codesign --force --deep --sign "$IDENTITY" --entitlements "$ENT" --timestamp=none "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv "$APP" 2>&1 | grep -E 'Signature=adhoc|TeamIdentifier' || true

mkdir -p dist
DMG="dist/Soundbites-${VERSION}-universal.dmg"
rm -f "$DMG"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Soundbites" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
ls -la dist
