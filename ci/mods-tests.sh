#!/bin/bash
# Build and run the mod manager's host tests (tests/mods/main.swift) on the
# build Mac: libarchive + mod_archive.c for macOS, fixtures, then the test
# program inside a case-sensitive APFS volume like the iPhone's.
set -euo pipefail

R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="${RUNNER_TEMP:-$(mktemp -d)}/mods-tests"
rm -rf "$T" && mkdir -p "$T/fixtures"

HOST=macos bash "$R/build/libarchive-ios/build.sh"
LIB="$R/build/libarchive-ios/obj-macos/libmadeira_archive.a"

python3 "$R/tests/mods/make_fixtures.py" "$T/fixtures"
mkdir -p "$T/p/Plain/meshes" && printf rock > "$T/p/Plain/meshes/rock.nif"
(cd "$T/p" && 7zz a -bd "$T/fixtures/plain.7z" Plain >/dev/null)

xcrun swiftc -O -o "$T/mods-tests" \
    "$R/app/Madeira/ModManagerCore.swift" "$R/app/Madeira/Fomod.swift" "$R/tests/mods/main.swift" \
    -import-objc-header "$R/app/Madeira/ModArchive.h" "$LIB" -lz -lbz2 -liconv -llzma

hdiutil create -quiet -size 300m -fs "Case-sensitive APFS" -volname ModTests "$T/vol.dmg"
hdiutil attach -quiet "$T/vol.dmg" -mountpoint "$T/vol"
trap 'hdiutil detach -quiet "$T/vol" || true' EXIT
"$T/mods-tests" "$T/fixtures" "$T/vol/scratch"
