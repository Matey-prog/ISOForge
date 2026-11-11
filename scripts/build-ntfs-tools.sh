#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/Vendor/ntfs-3g/source/checkout"
DEST="$ROOT/Vendor/ntfs-3g/bin"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
VERSION="2026.9.28"
COMMIT="7f0f841fc52cf719106c5c93bafe465004e36816"
mkdir -p "$DEST"
ACTUAL="$(git -C "$SOURCE" rev-parse HEAD)"
if [[ "$ACTUAL" != "$COMMIT" ]]; then
  echo "Unexpected ntfs-3g source revision: $ACTUAL" >&2
  exit 1
fi
if [[ ! -f "$SOURCE/configure" ]]; then
  (cd "$SOURCE" && /opt/homebrew/bin/aclocal -I m4 -I /opt/homebrew/share/aclocal && LIBTOOLIZE=/opt/homebrew/bin/glibtoolize /opt/homebrew/bin/autoreconf --install --force)
fi
if [[ ! -f "$SOURCE/Makefile" ]]; then
  (cd "$SOURCE" && CFLAGS="-O2 -isysroot $SDKROOT -mmacosx-version-min=14.0" ./configure \
    --prefix="$ROOT/Vendor/ntfs-3g/stage" --disable-ntfs-3g --disable-crypto --disable-ldconfig \
    --disable-mtab --disable-plugins --disable-posix-acls --disable-xattr-mappings --with-fuse=internal)
fi
make -C "$SOURCE/libntfs-3g" -j4
make -C "$SOURCE/ntfsprogs" -j4 mkntfs
/usr/bin/clang -std=gnu11 -D_GNU_SOURCE -DHAVE_CONFIG_H -I"$SOURCE" -I"$SOURCE/include/ntfs-3g" \
  -isysroot "$SDKROOT" -mmacosx-version-min=14.0 -O2 "$SOURCE/ISOForgeNTFS.c" \
  -o "$DEST/ntfs-writer" -L"$SOURCE/libntfs-3g/.libs" -lntfs-3g -framework CoreFoundation -framework CoreServices
cp "$SOURCE/ntfsprogs/.libs/mkntfs" "$DEST/mkntfs"
cp "$SOURCE/libntfs-3g/.libs/libntfs-3g.91.dylib" "$DEST/libntfs-3g.91.dylib"
install_name_tool -change "$ROOT/Vendor/ntfs-3g/stage/lib/libntfs-3g.91.dylib" \
  @executable_path/libntfs-3g.91.dylib "$DEST/ntfs-writer"
install_name_tool -change "$ROOT/Vendor/ntfs-3g/stage/lib/libntfs-3g.91.dylib" \
  @executable_path/../libntfs-3g.91.dylib "$DEST/mkntfs"
install_name_tool -change /tmp/isoforge-ntfs/lib/libntfs-3g.91.dylib \
  @executable_path/../libntfs-3g.91.dylib "$DEST/ntfs-writer"
install_name_tool -change /tmp/isoforge-ntfs/lib/libntfs-3g.91.dylib \
  @executable_path/../libntfs-3g.91.dylib "$DEST/mkntfs"
chmod 755 "$DEST/ntfs-writer" "$DEST/mkntfs"
cat > "$ROOT/Vendor/ntfs-3g/PROVENANCE.txt" <<EOF
NTFS-3G $VERSION
Upstream: https://github.com/tuxera/ntfs-3g
Tag: $VERSION
Commit: $COMMIT
Release source SHA-256: 350d9415c59f7c3fa74e23985ad2d56423c6a168337368f672e2e362d8f295c8
License: GPL-2.0-or-later; full upstream source and COPYING are bundled.
Build: scripts/build-ntfs-tools.sh (requires Xcode Command Line Tools and Homebrew autotools)
The helper uses libntfs-3g directly on an unmounted raw partition. No NTFS filesystem driver is installed in macOS.
EOF
"$DEST/ntfs-writer" --help >/dev/null 2>&1 || [[ $? == 2 ]]
echo "Bundled NTFS tools built: $VERSION"
