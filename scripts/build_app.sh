#!/bin/bash
# Build do iRemoteAiPeek SEM Xcode — só com as Command Line Tools (swiftc).
# Compila universal (arm64 + x86_64), monta dist/iRemoteAiPeek.app e assina ad-hoc.
# Uso: scripts/build_app.sh
#
# Com Xcode instalado também dá para usar o project.yml (xcodegen generate).

set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="iRemoteAiPeek"
BUNDLE_ID="com.smartfull.iremoteaipeek"
MIN_MACOS="13.0"
VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml)
BUILD=$(sed -n 's/^ *CURRENT_PROJECT_VERSION: *"\(.*\)"/\1/p' project.yml)

BUILD_DIR="build"
APP="dist/${APP_NAME}.app"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
SOURCES=$(find App Core Utilities -name '*.swift' | sort)

rm -rf "$BUILD_DIR" "$APP"
mkdir -p "$BUILD_DIR" "$APP/Contents/MacOS" "$APP/Contents/Resources"

for ARCH in arm64 x86_64; do
    echo "→ compilando ${ARCH}"
    # shellcheck disable=SC2086
    swiftc -O -swift-version 5 -parse-as-library \
        -sdk "$SDK" -target "${ARCH}-apple-macos${MIN_MACOS}" \
        -module-name "$APP_NAME" \
        -o "$BUILD_DIR/${APP_NAME}-${ARCH}" $SOURCES
done

echo "→ juntando em binário universal"
lipo -create "$BUILD_DIR/${APP_NAME}-arm64" "$BUILD_DIR/${APP_NAME}-x86_64" \
    -output "$APP/Contents/MacOS/${APP_NAME}"

echo "→ Info.plist (v${VERSION} build ${BUILD})"
sed -e "s/\$(EXECUTABLE_NAME)/${APP_NAME}/" \
    -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/${BUNDLE_ID}/" \
    -e "s/\$(PRODUCT_NAME)/${APP_NAME}/" \
    -e "s/\$(MARKETING_VERSION)/${VERSION}/" \
    -e "s/\$(CURRENT_PROJECT_VERSION)/${BUILD}/" \
    -e "s/\$(MACOSX_DEPLOYMENT_TARGET)/${MIN_MACOS}/" \
    App/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

if [[ ! -f Resources/AppIcon.icns ]]; then
    echo "→ gerando ícone"
    mkdir -p "$BUILD_DIR/AppIcon.iconset"
    swift scripts/generate_icon.swift "$BUILD_DIR/AppIcon.iconset" laranja >/dev/null
    iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "→ assinatura ad-hoc"
codesign --force --sign - "$APP"

echo "→ arquiteturas: $(lipo -archs "$APP/Contents/MacOS/${APP_NAME}")"
echo "✓ $APP"
