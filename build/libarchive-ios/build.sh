#!/bin/bash
# Build libarchive (zip, 7z and RAR4/RAR5 reading) for iOS arm64, plus the
# mod manager's small C entry point (mod_archive.c), as one static archive
# the app links: app/Madeira/libmadeira_archive.a (git-ignored).
#
# Consumer: the mod manager (app/Madeira/Mod*.swift) unpacks a mod archive
# through mod_archive_extract (app/Madeira/ModArchive.h).
#
# Dependencies are the SDK's own: zlib, bzip2, iconv, and liblzma (the SDK
# ships liblzma.tbd without headers, so the headers come from the pinned xz
# release; its API is stable across 5.x). No crypto library: encrypted
# archives are reported as such, not opened.
#
# HOST=macos builds the same library for the Mac running the build instead
# (ci/mods-tests.sh links it into the host tests).
set -euo pipefail

BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$BUILD_DIR/../.." && pwd)"
HOST="${HOST:-ios}"
OBJ_DIR="$BUILD_DIR/obj-$HOST"
SRC_DIR="$BUILD_DIR/src"

LIBARCHIVE_VER=3.8.9
LIBARCHIVE_SHA=888c934f9d95648ecb9163dc8e23ab80a476ecb81a8f1154704a227b5b676dde
XZ_VER=5.8.3
XZ_SHA=fff1ffcf2b0da84d308a14de513a1aa23d4e9aa3464d17e64b9714bfdd0bbfb6

mkdir -p "$SRC_DIR" "$OBJ_DIR"

fetch() {
    local url=$1 file=$2 sha=$3
    [ -f "$SRC_DIR/$file" ] || curl -fsSL -o "$SRC_DIR/$file" "$url"
    echo "$sha  $SRC_DIR/$file" | shasum -a 256 -c - >/dev/null
    tar -xJf "$SRC_DIR/$file" -C "$OBJ_DIR"
}
[ -d "$OBJ_DIR/libarchive-$LIBARCHIVE_VER" ] || fetch \
    "https://github.com/libarchive/libarchive/releases/download/v$LIBARCHIVE_VER/libarchive-$LIBARCHIVE_VER.tar.xz" \
    "libarchive-$LIBARCHIVE_VER.tar.xz" "$LIBARCHIVE_SHA"
[ -d "$OBJ_DIR/xz-$XZ_VER" ] || fetch \
    "https://github.com/tukaani-project/xz/releases/download/v$XZ_VER/xz-$XZ_VER.tar.xz" \
    "xz-$XZ_VER.tar.xz" "$XZ_SHA"

if [ "$HOST" = ios ]; then
    SDK=$(xcrun --sdk iphoneos --show-sdk-path)
    PLATFORM_ARGS=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0)
    CC_TARGET=(-arch arm64 -isysroot "$SDK" -miphoneos-version-min=17.0)
else
    SDK=$(xcrun --sdk macosx --show-sdk-path)
    PLATFORM_ARGS=(-DCMAKE_OSX_SYSROOT=macosx -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0)
    CC_TARGET=(-arch arm64 -isysroot "$SDK" -mmacosx-version-min=13.0)
fi

B="$OBJ_DIR/build"
cmake -S "$OBJ_DIR/libarchive-$LIBARCHIVE_VER" -B "$B" -G "Unix Makefiles" \
    "${PLATFORM_ARGS[@]}" -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF -DENABLE_TEST=OFF -DENABLE_INSTALL=OFF \
    -DENABLE_TAR=OFF -DENABLE_CPIO=OFF -DENABLE_CAT=OFF -DENABLE_UNZIP=OFF \
    -DENABLE_XATTR=OFF -DENABLE_ACL=OFF -DENABLE_LIBXML2=OFF -DENABLE_EXPAT=OFF \
    -DENABLE_OPENSSL=OFF -DENABLE_MBEDTLS=OFF -DENABLE_NETTLE=OFF -DENABLE_CNG=OFF \
    -DENABLE_LZ4=OFF -DENABLE_ZSTD=OFF -DENABLE_LZO=OFF -DENABLE_LIBB2=OFF \
    -DENABLE_ZLIB=ON -DENABLE_BZip2=ON -DENABLE_ICONV=ON -DENABLE_LZMA=ON \
    -DLIBLZMA_INCLUDE_DIR="$OBJ_DIR/xz-$XZ_VER/src/liblzma/api" \
    -DLIBLZMA_LIBRARY="$SDK/usr/lib/liblzma.tbd" \
    -DLIBLZMA_HAS_AUTO_DECODER=ON -DLIBLZMA_HAS_EASY_ENCODER=ON -DLIBLZMA_HAS_LZMA_PRESET=ON
cmake --build "$B" --target archive_static -j"$(sysctl -n hw.ncpu)"

xcrun clang "${CC_TARGET[@]}" -O2 -Wall -I"$OBJ_DIR/libarchive-$LIBARCHIVE_VER/libarchive" \
    -I"$REPO_ROOT/app/Madeira" -c "$BUILD_DIR/mod_archive.c" -o "$OBJ_DIR/mod_archive.o"
OUT="$OBJ_DIR/libmadeira_archive.a"
xcrun libtool -static -o "$OUT" "$B/libarchive/libarchive.a" "$OBJ_DIR/mod_archive.o"
if [ "$HOST" = ios ]; then
    cp "$OUT" "$REPO_ROOT/app/Madeira/libmadeira_archive.a"
    echo "-> app/Madeira/libmadeira_archive.a ($(wc -c < "$OUT" | tr -d ' ') bytes)"
else
    echo "-> $OUT"
fi
