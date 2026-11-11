#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=1.14.5
SHA=84221a3abd5b91228f15f8e6065c335a336237b5738197b75bf419eea561a194
VENDOR="$ROOT/Vendor/wimlib"
CACHE="${FORGE_BUILD_CACHE:-$HOME/Library/Caches/ua.isoforge}/wimlib-$VERSION"
if [[ -x "$VENDOR/bin/wimlib-imagex" && -f "$VENDOR/PROVENANCE.txt" ]]; then exit 0; fi
mkdir -p "$CACHE" "$VENDOR/bin" "$VENDOR/licenses" "$VENDOR/source"
ARCHIVE="$CACHE/wimlib-$VERSION.tar.gz"
if [[ ! -f "$ARCHIVE" ]]; then
  curl --fail --location --retry 3 "https://wimlib.net/downloads/wimlib-$VERSION.tar.gz" -o "$ARCHIVE"
fi
ACTUAL="$(shasum -a 256 "$ARCHIVE" | cut -d ' ' -f 1)"
if [[ "$ACTUAL" != "$SHA" ]]; then echo 'wimlib checksum mismatch' >&2; exit 1; fi
tar -xzf "$ARCHIVE" -C "$CACHE"
cd "$CACHE/wimlib-$VERSION"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export MACOSX_DEPLOYMENT_TARGET=14.0
export CC="$(xcrun --find clang)"
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export CFLAGS="-O2 -isysroot $SDKROOT -mmacosx-version-min=14.0"
export LDFLAGS="-isysroot $SDKROOT -mmacosx-version-min=14.0"
./configure --disable-shared --enable-static --without-ntfs-3g --without-fuse --prefix="$CACHE/install" > "$CACHE/configure.log" 2>&1
make -j4 > "$CACHE/make.log" 2>&1
cp wimlib-imagex "$VENDOR/bin/"
cp COPYING* "$VENDOR/licenses/"
cp "$ARCHIVE" "$VENDOR/source/"
cat > "$VENDOR/PROVENANCE.txt" <<EOF
wimlib $VERSION, built locally from unmodified upstream source for $(uname -m).
Source: https://wimlib.net/downloads/wimlib-$VERSION.tar.gz
SHA-256: $SHA (verified against Homebrew's wimlib source metadata)
Build: --disable-shared --enable-static --without-ntfs-3g --without-fuse
Minimum macOS: 14.0
Complete corresponding source is included in source/; this build script is in the project.
EOF
"$VENDOR/bin/wimlib-imagex" --version
otool -L "$VENDOR/bin/wimlib-imagex"
