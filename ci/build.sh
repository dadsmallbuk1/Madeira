#!/bin/bash
# CI driver for the personal fork: builds every ignored input the Xcode
# project links (docs/BUILDING.md), then the app (Debug), then an IPA.
#
# Each stage logs to $LOGS/<stage>.log. With KEEP_GOING=1 a failed stage is
# recorded and the next one still runs, so one CI run reports as many
# problems as possible; the final summary lists them.
#
# Usage: ci/build.sh [stage...]   (no arguments: all stages in order)
set -uo pipefail

R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOGS="${LOGS:-$R/ci-logs}"
KEEP_GOING="${KEEP_GOING:-1}"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
MINGW_NAME=llvm-mingw-20260421-ucrt-macos-universal
MINGW_SHA=bd85a3975723815cef28dbbd2ca2cb0c926f6b348a12a0453f39f7af273cb3f7
mkdir -p "$LOGS" "$R/toolchains"
export PATH="/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/flex/bin:/opt/homebrew/opt/llvm/bin:$PATH"

FAILED=()

stage_mingw() {
    local d="$R/toolchains/$MINGW_NAME"
    [ -x "$d/bin/aarch64-w64-mingw32-clang" ] && return 0
    local t="$R/toolchains/$MINGW_NAME.tar.xz"
    curl -fsSL -o "$t" "https://github.com/mstorsjo/llvm-mingw/releases/download/20260421/$MINGW_NAME.tar.xz"
    echo "$MINGW_SHA  $t" | shasum -a 256 -c -
    tar -xJf "$t" -C "$R/toolchains"
    rm -f "$t"
}

stage_freetype() {
    [ -d "$R/research/freetype" ] || \
        git clone --depth 1 --branch VER-2-13-3 https://github.com/freetype/freetype.git "$R/research/freetype"
    bash "$R/build/freetype-ios/build.sh"
}

stage_gnutls() { bash "$R/build/gnutls-ios/build.sh"; }
stage_ffmpeg() { bash "$R/build/ffmpeg/build.sh"; }

# Wine's configured trees. build-macos supplies config.h and the widl-made
# headers the iOS unix libraries compile against; build-arm64ec supplies the
# PE-only generated headers (dwrite.h) that ntdll-unix names explicitly.
# Wine's single top-level Makefile has no "include" target (that name is the
# directory), so the generated headers are asked for one by one: every
# include/*.idl becomes include/<name>.h.
wine_headers() {
    local tree="$1" targets=()
    for idl in "$R"/wine/include/*.idl "$R"/wine/include/wine/*.idl; do
        [ -f "$idl" ] || continue
        local rel="${idl#$R/wine/}"
        targets+=("${rel%.idl}.h")
    done
    make -C "$tree" -j"$JOBS" -k "${targets[@]}" || true
    [ -f "$tree/include/objidlbase.h" ] && [ -f "$tree/include/wtypes.h" ]
}

stage_wine_trees() {
    export PATH="$R/toolchains/$MINGW_NAME/bin:$PATH"
    if [ ! -f "$R/wine/build-macos/config.status" ]; then
        mkdir -p "$R/wine/build-macos"
        (cd "$R/wine/build-macos" && ../configure --without-x --disable-tests --enable-winegstreamer) || return 1
    fi
    wine_headers "$R/wine/build-macos" || return 1
    if [ ! -f "$R/wine/build-arm64ec/config.status" ]; then
        mkdir -p "$R/wine/build-arm64ec"
        (cd "$R/wine/build-arm64ec" && ../configure --enable-archs=arm64ec --without-x --disable-tests --enable-winegstreamer) || return 1
    fi
    wine_headers "$R/wine/build-arm64ec"
}

stage_ntdll() { bash "$R/build/ntdll-unix/build.sh"; }
stage_win32u() { bash "$R/build/win32u-unix/build.sh"; }
stage_wineserver() { bash "$R/ci/wineserver-base.sh" && bash "$R/build/wineserver/build.sh"; }
# fex-ios/build.sh configures only when there is no cache yet; configure it
# here first with the same options plus the processor, which a CMake iOS
# cross build leaves empty (FEX's CMakeLists stops on an empty one), and a
# fixed CPU tuning: the default "native" reads /proc/cpuinfo, which macOS
# lacks. apple-m1 (ARMv8.5) is a subset of every iPhone that runs Madeira.
stage_fex() {
    local B="$R/FEX/build-ios"
    if [ ! -f "$B/CMakeCache.txt" ]; then
        cmake -S "$R/FEX" -B "$B" -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_SYSTEM_PROCESSOR=arm64             -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0             -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF -DBUILD_THUNKS=OFF -DBUILD_FEXCONFIG=OFF             -DBUILD_FEX_LINUX_TESTS=OFF -DENABLE_FEX_ALLOCATOR=OFF -DENABLE_ASSERTIONS=OFF             -DENABLE_CLANG_THUNKS=ON -DENABLE_CCACHE=ON -DTUNE_CPU=apple-m1 || return 1
    fi
    bash "$R/build/fex-ios/build.sh" || return 1
    # The app also links libJemallocLibs.a (FEXCore's allocator hooks), which
    # fex-ios/build.sh does not build.
    cmake --build "$B" --target JemallocLibs || return 1
    for a in FEXCore/Source/libFEXCore.a FEXCore/Source/libFEXCore_Base.a FEXCore/Source/libJemallocLibs.a              External/SoftFloat-3e/libsoftfloat_3e.a External/cephes/libcephes_128bit.a External/fmt/libfmt.a              External/xxhash/cmake_unofficial/libxxhash.a; do
        [ -f "$B/$a" ] || { echo "missing $B/$a"; return 1; }
    done
}

# airconv includes headers made from its Metal shaders (src/airconv/meson.build:
# metal -> .air -> xxd -i); dxmt-ios/build.sh expects them in shader-headers.
stage_dxmt() {
    local H="$R/build/dxmt-ios/shader-headers"
    mkdir -p "$H"
    # Newer Metal compilers give the internal __metal_atomic_fetch_add_explicit
    # one more parameter; the copy compiled here uses the public
    # atomic_fetch_add_explicit, which means the same on every compiler.
    for m in "$R"/dxmt/src/airconv/shaders/*.metal; do
        local n; n=$(basename "$m" .metal)
        sed -E 's/__metal_atomic_fetch_add_explicit\(([a-z_]+), 1, int\(memory_order_relaxed\), __METAL_MEMORY_SCOPE_THREADGROUP__\)/atomic_fetch_add_explicit((threadgroup atomic_int *)\1, 1, memory_order_relaxed)/'             "$m" > "$H/$n.metal"
        (cd "$H" && xcrun -sdk macosx metal -std=metal3.1 --target=air64-apple-macos14.0 -o "$n.air" -c "$n.metal" &&
            xxd -n "$n" -i "$n.air" "$n.h") || return 1
    done
    bash "$R/build/dxmt-ios/build.sh" || return 1
    xcrun -sdk iphoneos libtool -static -o "$R/build/dxmt-ios/libdxmt_combined.a" \
        "$R/build/dxmt-ios/obj"/*.o "$R/toolchains/llvm-ios-build/lib"/*.a || return 1
    cp "$R/build/dxmt-ios/libdxmt_combined.a" "$R/app/Madeira/libdxmt_combined.a"
}

stage_rppairing() { bash "$R/build/rppairing-ios/build.sh"; }
stage_libarchive() { bash "$R/build/libarchive-ios/build.sh"; }

stage_app() {
    # The Microsoft runtime DLLs are never committed; the folder the project
    # names stays empty here and the DLLs are added to the IPA afterwards.
    mkdir -p "$R/app/Madeira/x86_64-vcruntime"
    xcodebuild -project "$R/app/Madeira.xcodeproj" -scheme Madeira -configuration Debug \
        -destination 'generic/platform=iOS' -derivedDataPath "$R/build/DerivedData" \
        CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= \
        AD_HOC_CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO \
        build
}

stage_ipa() {
    [[ " ${FAILED[*]:-} " == *" app "* ]] && { echo "app stage failed; no IPA"; return 1; }
    local app="$R/build/DerivedData/Build/Products/Debug-iphoneos/Madeira.app"
    [ -d "$app" ] || return 1
    rm -rf "$R/build/ipa" && mkdir -p "$R/build/ipa/Payload"
    cp -R "$app" "$R/build/ipa/Payload/"
    (cd "$R/build/ipa" && zip -qry -X ../Madeira-fork.ipa Payload)
    ls -la "$R/build/Madeira-fork.ipa"
}

ALL=(mingw freetype gnutls ffmpeg wine_trees ntdll win32u wineserver fex dxmt rppairing libarchive app ipa)
STAGES=("$@")
[ ${#STAGES[@]} -eq 0 ] && STAGES=("${ALL[@]}")

for s in "${STAGES[@]}"; do
    echo "::group::stage $s"
    start=$(date +%s)
    if "stage_$s" > >(tee "$LOGS/$s.log") 2>&1; then
        echo "stage $s OK ($(( $(date +%s) - start ))s)"
    else
        echo "::error::stage $s FAILED ($(( $(date +%s) - start ))s)"
        FAILED+=("$s")
        # Compiler errors of the per-file build scripts land in obj/*.err.
        for e in "$R"/build/*/obj/*.err; do
            [ -s "$e" ] && { echo "--- $e"; head -40 "$e"; } >> "$LOGS/$s.errfiles.log"
        done
        echo "::endgroup::"
        [ "$KEEP_GOING" = 1 ] || break
        continue
    fi
    echo "::endgroup::"
done

echo "Failed stages: ${FAILED[*]:-none}"
[ ${#FAILED[@]} -eq 0 ]
