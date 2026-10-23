#!/bin/sh
# Compila Paralelo y lo empaqueta como build/Paralelo.app (con el CLI `paralelo` dentro).
set -e
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)"

APP="build/Paralelo.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Ojo: el sistema de archivos de macOS no distingue mayúsculas, así que la app y el CLI
# no pueden llamarse "Paralelo" y "paralelo" en la misma carpeta.
cp "$BIN/ParaleloApp" "$APP/Contents/MacOS/ParaleloApp"
cp "$BIN/paralelo" "$APP/Contents/MacOS/paralelo"
if [ "$(ls "$APP/Contents/MacOS" | wc -l)" -ne 2 ]; then
    echo "Error: faltan ejecutables en $APP/Contents/MacOS" >&2
    exit 1
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>ParaleloApp</string>
    <key>CFBundleIdentifier</key><string>app.paralelo.Paralelo</string>
    <key>CFBundleName</key><string>Paralelo</string>
    <key>CFBundleDisplayName</key><string>Paralelo</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Firma ad-hoc para que macOS lo ejecute localmente. Antes se quitan los atributos extendidos
# (Finder, iCloud, cuarentena) porque codesign los rechaza.
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"

echo "Listo: $APP"
echo "Cópialo a /Applications o ábrelo con: open $APP"
