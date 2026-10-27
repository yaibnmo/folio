#!/bin/bash
# Compile Folio et assemble Folio.app.
#   ./build.sh            -> build/Folio.app
#   ./build.sh --install  -> copie aussi l'app dans /Applications
set -euo pipefail
cd "$(dirname "$0")"

echo "▶︎ Compilation (release)…"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/Folio"

APP="build/Folio.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/fr.lproj"
cp "$BIN" "$APP/Contents/MacOS/Folio"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/Folio.icns ]; then cp Resources/Folio.icns "$APP/Contents/Resources/Folio.icns"; fi
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "✔︎ $APP — $(du -sh "$APP" | cut -f1)"

echo "▶︎ Auto-test…"
"$APP/Contents/MacOS/Folio" --selftest "$PWD/selftest" || echo "✘ Auto-test en échec"

if [ "${1:-}" = "--install" ]; then
    rm -rf /Applications/Folio.app
    ditto "$APP" /Applications/Folio.app
    echo "✔︎ Installé dans /Applications/Folio.app"
fi
