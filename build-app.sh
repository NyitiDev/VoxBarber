#!/bin/bash
#
# build-app.sh — Hordozható VoxBarber.app bundle készítése.
#
# A script:
#   1. Release módban, universal (arm64 + x86_64) binárisként fordít.
#   2. Összerakja a VoxBarber.app csomagot a megfelelő struktúrával.
#   3. Beágyazza a SFBAudioEngine dinamikus frameworköket (Contents/Frameworks).
#   4. Bemásolja a resource bundle-t (logó) és beállítja az rpath-ot.
#   5. Legenerálja az Info.plist-et és az alkalmazás ikont.
#
# Eredmény: dist/VoxBarber.app — egyetlen, dupla kattintható, másik Macre
# (Intel és Apple Silicon) is átvihető egységként.
#
# Használat:  ./build-app.sh

set -euo pipefail

APP_NAME="VoxBarber"
BUNDLE_ID="dev.nyitrai.voxbarber"
VERSION="1.1"
MIN_MACOS="12.0"

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
APP_DIR="${DIST_DIR}/${APP_NAME}.app"
MACOS_DIR="${APP_DIR}/Contents/MacOS"
RES_DIR="${APP_DIR}/Contents/Resources"
FW_DIR="${APP_DIR}/Contents/Frameworks"

echo "==> 1/6  Universal release build (arm64 + x86_64)…"
swift build -c release --arch arm64 --arch x86_64

BIN_PATH="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
echo "    bin: ${BIN_PATH}"

echo "==> 2/6  App bundle struktúra létrehozása…"
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RES_DIR}" "${FW_DIR}"

cp "${BIN_PATH}/${APP_NAME}" "${MACOS_DIR}/${APP_NAME}"

echo "==> 3/6  Frameworkök beágyazása…"
for fw in "${BIN_PATH}"/*.framework; do
    [ -e "${fw}" ] || continue
    cp -R "${fw}" "${FW_DIR}/"
done

echo "==> 4/6  Resource bundle (logó) másolása…"
for bundle in "${BIN_PATH}"/*.bundle; do
    [ -e "${bundle}" ] || continue
    cp -R "${bundle}" "${RES_DIR}/"
done

echo "==> 5/6  rpath beállítása…"
# A futtatható a Contents/MacOS-ben van, a frameworkök a Contents/Frameworks-ben.
# A @loader_path-ról a ../Frameworks-re mutató rpath-ot adjuk hozzá.
install_name_tool -add_rpath "@loader_path/../Frameworks" "${MACOS_DIR}/${APP_NAME}" 2>/dev/null || true

echo "==> 6/6  Info.plist és ikon generálása…"

# Ikon: a logó PNG-ből .icns előállítása (ha elérhető a sips és iconutil).
LOGO_SRC="${ROOT_DIR}/Sources/VoxBarber/Resources/voxbarber_logo.png"
if [ -f "${LOGO_SRC}" ] && command -v sips >/dev/null && command -v iconutil >/dev/null; then
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "${ICONSET}"
    for size in 16 32 64 128 256 512 1024; do
        sips -s format png -z "${size}" "${size}" "${LOGO_SRC}" \
            --out "${ICONSET}/icon_${size}x${size}.png" >/dev/null 2>&1 || true
    done
    # Retina (@2x) változatok
    cp "${ICONSET}/icon_32x32.png"   "${ICONSET}/icon_16x16@2x.png"   2>/dev/null || true
    cp "${ICONSET}/icon_64x64.png"   "${ICONSET}/icon_32x32@2x.png"   2>/dev/null || true
    cp "${ICONSET}/icon_256x256.png" "${ICONSET}/icon_128x128@2x.png" 2>/dev/null || true
    cp "${ICONSET}/icon_512x512.png" "${ICONSET}/icon_256x256@2x.png" 2>/dev/null || true
    cp "${ICONSET}/icon_1024x1024.png" "${ICONSET}/icon_512x512@2x.png" 2>/dev/null || true
    iconutil -c icns "${ICONSET}" -o "${RES_DIR}/AppIcon.icns" 2>/dev/null || true
fi

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_MACOS}</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "==> Ad-hoc aláírás (hogy helyben fusson)…"
codesign --force --deep --sign - "${APP_DIR}" 2>/dev/null || \
    echo "    (codesign kihagyva – a másik gépen lehet, hogy jobb-katt > Megnyitás kell)"

echo ""
echo "✅ Kész:  ${APP_DIR}"
echo "   Architektúrák: $(lipo -archs "${MACOS_DIR}/${APP_NAME}")"
echo ""
echo "Átvitel a másik Macre: másold át a teljes '${APP_NAME}.app' mappát"
echo "(pl. tömörítve: ditto -c -k --keepParent '${APP_DIR}' '${DIST_DIR}/${APP_NAME}.zip')."
