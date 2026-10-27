#!/bin/bash
# Double-cliquez sur ce fichier : il fabrique Folio.app, l'installe dans Applications et l'ouvre.
cd "$(dirname "$0")"
osascript -e 'if application "Folio" is running then tell application "Folio" to quit' 2>/dev/null; sleep 1
./build.sh --install 2>&1 | tee build.log
if [ "${PIPESTATUS[0]}" -eq 0 ]; then
    LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
    "$LSREG" -u build/Folio.app >/dev/null 2>&1
    rm -rf build/Folio.app
    touch /Applications/Folio.app
    "$LSREG" -f /Applications/Folio.app >/dev/null 2>&1
    echo "✔︎ Terminé — ouverture de Folio"
    open /Applications/Folio.app
else
    echo "✘ La compilation a échoué (détails dans build.log)"
fi
