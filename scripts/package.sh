#!/bin/bash
# Fabrique Folio.app (universelle : Apple Silicon + Intel), puis Folio.dmg et Folio.zip dans dist/.
#   ./scripts/package.sh [version]
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-1.0.0}"
ARCHS=(--arch arm64 --arch x86_64)

echo "▶︎ Compilation universelle (version $VERSION)…"
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/Folio"

rm -rf dist
APP="dist/Folio.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/fr.lproj"
cp "$BIN" "$APP/Contents/MacOS/Folio"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
cp Resources/Folio.icns "$APP/Contents/Resources/Folio.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --deep --sign - "$APP"
lipo -info "$APP/Contents/MacOS/Folio"

echo "▶︎ Auto-test…"
"$APP/Contents/MacOS/Folio" --selftest "$PWD/dist/selftest"

echo "▶︎ Image disque…"
STAGE="dist/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Folio" -srcfolder "$STAGE" -ov -format UDZO "dist/Folio.dmg"
rm -rf "$STAGE"

ditto -c -k --keepParent "$APP" "dist/Folio.zip"
echo "✔︎ dist/Folio.dmg ($(du -h dist/Folio.dmg | cut -f1)) et dist/Folio.zip"
