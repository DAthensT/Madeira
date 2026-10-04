#!/bin/bash
# The base libwineserver.a build/wineserver/build.sh patches. That script only
# compiles the files Madeira changed and swaps them into an existing archive,
# which is not in the repository; on a clean checkout it stops with "No base
# libwineserver.a found". Reconstruction: every wine/server/*.c compiled with
# the same flags build.sh uses (a file that does not build for iOS is left out
# and reported). build.sh then replaces the patched members and renames the
# symbols that collide with win32u.
set -euo pipefail
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="$R/build/wineserver"
WINE_SRC="$R/wine"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
OBJ="$BUILD_DIR/obj/base"
mkdir -p "$OBJ"
[ -f "$BUILD_DIR/obj/libwineserver.a" ] && { echo "base archive exists"; exit 0; }

CC_FLAGS=(
    -arch arm64 -isysroot "$SDK" -miphoneos-version-min=17.0 -O2
    -I"$WINE_SRC/include" -I"$WINE_SRC/include/wine"
    -I"$WINE_SRC/build-macos/include"
    -I"$BUILD_DIR" -I"$WINE_SRC/server"
    -I"$R/build/ntdll-unix/shims"
    -I"$R/build/madsync" -DHAVE_LINUX_NTSYNC_H=1
    -include "$BUILD_DIR/config_ios.h"
    -include stdarg.h
    -include "$BUILD_DIR/unicode_fix.h"
    -include "$BUILD_DIR/wineserver_ios_kill.h"
    -DBINDIR=\"/usr/local/bin\" -DDATADIR=\"/usr/local/share\"
    -D__WINESRC__ -DWINE_IOS=1
    -Dmain=wineserver_main
    -Wno-implicit-function-declaration
)
ok=0; skipped=""
for src in "$WINE_SRC"/server/*.c; do
    name=$(basename "$src" .c)
    if xcrun -sdk iphoneos clang "${CC_FLAGS[@]}" -c "$src" -o "$OBJ/$name.o" 2>"$OBJ/$name.err"; then
        ok=$((ok + 1))
    else
        skipped="$skipped $name"
        grep -m 5 "error:" "$OBJ/$name.err" || true
    fi
done
echo "base: $ok objects; left out:${skipped:- none}"
ar rcs "$BUILD_DIR/obj/libwineserver.a" "$OBJ"/*.o
