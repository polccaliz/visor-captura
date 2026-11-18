#!/bin/bash
# Compila "Visor Captura.app" amb icona i crea "Visor Captura.dmg" a l'Escriptori.
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "Falten les eines de desenvolupament. S'obrirà l'instal·lador; quan acabi, torna a executar aquest script."
  xcode-select --install || true
  exit 1
fi

NAME="Visor Captura"
APP="build/$NAME.app"
DMG="$HOME/Desktop/$NAME.dmg"

# Tanca la versió antiga si està oberta
pkill -x VisorCaptura 2>/dev/null || true

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "Compilant…"
swiftc -O -swift-version 5 main.swift -o "$APP/Contents/MacOS/VisorCaptura" \
  -framework Cocoa -framework AVFoundation -framework CoreMedia

codesign --force --deep -s - "$APP"

echo "Creant DMG…"
STAGE="build/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$NAME.app"
ln -s /Applications "$STAGE/Aplicacions"
rm -f "$DMG"
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

# Esborra la versió trencada anterior i reinicia la memòria d'icones
rm -rf "/Applications/$NAME.app"
touch "$STAGE/$NAME.app"

echo "Fet: $DMG"
open "$DMG"
