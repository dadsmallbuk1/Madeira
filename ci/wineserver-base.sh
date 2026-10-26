#!/bin/bash
# build/wineserver/build.sh only REPLACES objects in an existing
# libwineserver.a (the "base library", app/Madeira/libwineserver.a, which is
# git-ignored and so absent from a clean clone). This makes that base: every
# wine/server/*.c compiled with the same flags build.sh uses. build.sh then
# swaps in its iOS versions as usual.
set -uo pipefail

R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$R/build/wineserver"
WINE_SRC="$R/wine"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
OBJ_DIR="$BUILD_DIR/obj"
BASE_DIR="$OBJ_DIR/base"
mkdir -p "$BASE_DIR"

[ -f "$OBJ_DIR/libwineserver.a" ] && { echo "base library already present"; exit 0; }

CC_FLAGS=(
    -arch arm64 -isysroot "$SDK" -miphoneos-version-min=17.0 -O2
    -I"$WINE_SRC/include" -I"$WINE_SRC/include/wine"
    -I"$WINE_SRC/build-macos/include"
    -I"$BUILD_DIR" -I"$WINE_SRC/server"
    -I"$R/build/ntdll-unix/shims"
    -I"$BUILD_DIR/../madsync" -DHAVE_LINUX_NTSYNC_H=1
    -include "$BUILD_DIR/config_ios.h"
    -include stdarg.h
    -include "$BUILD_DIR/unicode_fix.h"
    -include "$BUILD_DIR/wineserver_ios_kill.h"
    -DBINDIR=\"/usr/local/bin\" -DDATADIR=\"/usr/local/share\"
    -D__WINESRC__ -DWINE_IOS=1
    -Dmain=wineserver_main
    -Wno-implicit-function-declaration
)

ok=0; bad=()
for src in "$WINE_SRC"/server/*.c; do
    name=$(basename "$src" .c)
    if xcrun -sdk iphoneos clang "${CC_FLAGS[@]}" -c "$src" -o "$BASE_DIR/$name.o" 2>"$BASE_DIR/$name.err"; then
        ok=$((ok + 1))
    else
        bad+=("$name"); echo "--- $name"; head -20 "$BASE_DIR/$name.err"
    fi
done
echo "base objects: $ok built, ${#bad[@]} failed: ${bad[*]:-}"
xcrun -sdk iphoneos ar rcs "$OBJ_DIR/libwineserver.a" "$BASE_DIR"/*.o
