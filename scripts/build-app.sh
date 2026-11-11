#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="${FORGE_BUILD_CACHE:-$HOME/Library/Caches/ua.isoforge}"
CONFIG=release
INSTALL=0
for ARG in "$@"; do
  case "$ARG" in
    --debug) CONFIG=debug ;;
    --install) INSTALL=1 ;;
    *) echo "Usage: scripts/build-app.sh [--debug] [--install]" >&2; exit 2 ;;
  esac
done
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$CACHE/clang-module-cache" "$CACHE/swift-module-cache"
export CLANG_MODULE_CACHE_PATH="$CACHE/clang-module-cache"
export SWIFT_MODULECACHE_PATH="$CACHE/swift-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CACHE/swift-module-cache"
bash "$ROOT/scripts/fetch-wimlib.sh"
cd "$ROOT"
xcrun swift build --disable-sandbox --scratch-path "$CACHE/swift-build" -c "$CONFIG"
STAGE="$(mktemp -d "$CACHE/bundle.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/ISO Forge.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Licenses/wimlib/source"
cp "$CACHE/swift-build/$CONFIG/ISOForge" "$APP/Contents/MacOS/"
cp "$CACHE/swift-build/$CONFIG/ForgeWriter" "$APP/Contents/MacOS/"
cp "$ROOT/Vendor/wimlib/bin/wimlib-imagex" "$APP/Contents/MacOS/"
chmod 755 "$APP/Contents/MacOS/"*
cp "$ROOT/Vendor/wimlib/licenses/"* "$APP/Contents/Resources/Licenses/wimlib/"
cp "$ROOT/Vendor/wimlib/source/"*.tar.gz "$APP/Contents/Resources/Licenses/wimlib/source/"
cp "$ROOT/Vendor/wimlib/PROVENANCE.txt" "$APP/Contents/Resources/Licenses/wimlib/"
cp "$ROOT/scripts/fetch-wimlib.sh" "$APP/Contents/Resources/Licenses/wimlib/BUILD.sh"
cp "$ROOT/README.md" "$APP/Contents/Resources/README.md"
xcrun swift -module-cache-path "$CACHE/swift-module-cache" "$ROOT/scripts/make-icon.swift" "$STAGE/Forge.iconset"
iconutil -c icns "$STAGE/Forge.iconset" -o "$APP/Contents/Resources/Forge.icns"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>ISO Forge</string>
<key>CFBundleDisplayName</key><string>ISO Forge</string>
<key>CFBundleIdentifier</key><string>ua.isoforge.app</string>
<key>CFBundleExecutable</key><string>ISOForge</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.2.2</string>
<key>CFBundleVersion</key><string>2</string>
<key>CFBundleIconFile</key><string>Forge</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>ISO Forge, 2026. Bundled wimlib is GPL v3 or later; source and licenses are included.</string>
<key>CFBundleDevelopmentRegion</key><string>uk</string>
<key>CFBundleLocalizations</key><array><string>uk</string></array>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>Завантажувальний образ</string>
<key>CFBundleTypeExtensions</key><array><string>iso</string><string>img</string></array>
<key>CFBundleTypeRole</key><string>Viewer</string>
<key>LSHandlerRank</key><string>Alternate</string>
</dict></array>
</dict></plist>
EOF
printf 'APPL????' > "$APP/Contents/PkgInfo"
for EXECUTABLE in ISOForge ForgeWriter wimlib-imagex; do
  codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/$EXECUTABLE"
done
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"
plutil -lint "$APP/Contents/Info.plist"
mkdir -p "$ROOT/dist/ISO Forge.app"
rsync -rLt --delete --exclude='._*' "$APP/" "$ROOT/dist/ISO Forge.app/"
codesign --verify --deep --strict "$ROOT/dist/ISO Forge.app"
if [[ "$INSTALL" == 1 ]]; then
  TARGET='/Applications/ISO Forge.app'
  INSTALL_STAGE="$(mktemp -d /Applications/.isoforge-install.XXXXXX)"
  ditto "$APP" "$INSTALL_STAGE/ISO Forge.app"
  codesign --verify --deep --strict "$INSTALL_STAGE/ISO Forge.app"
  if [[ -e "$TARGET" ]]; then
    BACKUP="$CACHE/backups/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP"
    mv "$TARGET" "$BACKUP/"
  fi
  mv "$INSTALL_STAGE/ISO Forge.app" "$TARGET"
  rmdir "$INSTALL_STAGE"
  codesign --verify --deep --strict "$TARGET"
  echo "Installed: $TARGET"
fi
echo "Built: $ROOT/dist/ISO Forge.app"
du -sh "$ROOT/dist/ISO Forge.app"
