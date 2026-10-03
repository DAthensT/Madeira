#!/bin/bash
# Build the three ARM64EC modules Slay the Spire 2 (Godot 4, D3D12 through
# DirectComposition) needs on top of Madeira 0.1.1, without macOS:
#
#   madeira_d3d12.dll / d3d12.dll  composition swapchains + MadeiraD3D12SwapChainSetHwnd
#   dcomp.dll                      minimal DirectComposition that binds them at Commit
#   dxgi.dll                       DXMT with CreateSwapChainForComposition for D3D12 queues
#
# Only llvm-mingw is needed. winemetal's import library is generated from the
# winemetal.dll already in the farm, and dxgi.dll is compiled directly from
# the DXMT sources meson would use for an arm64ec build (headless wsi), since
# DXMT's meson project needs xcrun and xxd even for its Windows modules.
#
# usage: build-dlls.sh <llvm-mingw bin dir> <dxmt source dir> <out dir>
set -eu
MINGW="$1"; DXMT="$(cd "$2" && pwd)"; OUT="$3"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FARM="$REPO_ROOT/app/Madeira/arm64ec-windows"
CC="$MINGW/arm64ec-w64-mingw32-clang"
CXX="$MINGW/arm64ec-w64-mingw32-clang++"
mkdir -p "$OUT/obj/dxgi" "$OUT/obj/util" "$OUT/obj/dxmt"
OUT="$(cd "$OUT" && pwd)"

echo "=== libwinemetal.a (from the shipped winemetal.dll) ==="
"$MINGW/gendef" - "$FARM/winemetal.dll" > "$OUT/obj/winemetal.def"
"$MINGW/arm64ec-w64-mingw32-dlltool" -m arm64ec -d "$OUT/obj/winemetal.def" -l "$OUT/obj/libwinemetal.a"

echo "=== madeira_d3d12.dll / d3d12.dll ==="
SRC="$REPO_ROOT/madeira-d3d12/src/pe"
"$CC" -shared -O2 -Wall -Wno-unused-function \
    -o "$OUT/madeira_d3d12.dll" "$SRC/madeira_d3d12.c" "$SRC/d3d12.def" \
    -I"$SRC" -I"$REPO_ROOT/madeira-d3d12/src" -I"$DXMT/src/winemetal" \
    -L"$OUT/obj" -lwinemetal -luuid -lole32
cp "$OUT/madeira_d3d12.dll" "$OUT/d3d12.dll"

echo "=== dcomp.dll ==="
"$CC" -shared -O2 -Wall \
    -o "$OUT/dcomp.dll" "$REPO_ROOT/madeira-d3d12/src/dcomp/dcomp.c" "$REPO_ROOT/madeira-d3d12/src/dcomp/dcomp.def" \
    -luuid

echo "=== dxgi.dll (DXMT $(git -C "$DXMT" describe --always 2>/dev/null || echo unknown)) ==="
printf '#pragma once\n\n#define DXMT_VERSION "%s"\n' "$(git -C "$DXMT" describe --always 2>/dev/null || echo sts2)" \
    > "$OUT/obj/dxgi/version.h"
FLAGS=(-O2 -DNDEBUG -DNOMINMAX -D_WIN32_WINNT=0xa00 -DDXMT_IOS=1 -DDXMT_PAGE_SIZE=4096 -fblocks
       -Wno-missing-field-initializers -Wno-unused-parameter -Wno-cast-function-type
       -Wno-unused-private-field -Wno-microsoft-exception-spec -Wno-extern-c-compat
       -Wno-unused-const-variable -Wno-missing-braces
       -I"$DXMT/include" -I"$DXMT/include/native/directx" -I"$DXMT/src" -I"$DXMT/src/util"
       -I"$DXMT/src/dxmt" -I"$DXMT/src/winemetal" -I"$DXMT/src/dxgi" -I"$OUT/obj/dxgi")
for f in dxgi_adapter dxgi_factory dxgi_output dxgi_options dxgi; do
    "$CXX" -std=c++20 "${FLAGS[@]}" -c "$DXMT/src/dxgi/$f.cpp" -o "$OUT/obj/dxgi/$f.o"
done
# src/util/meson.build for an aarch64 (arm64ec) Windows host.
for f in util_env util_string util_bloom util_futex thread com/com_guid com/com_private_data \
         config/config log/log sha1/sha1_util wsi_monitor_headless wsi_window_headless wsi_platform_win32; do
    "$CXX" -std=c++20 "${FLAGS[@]}" -c "$DXMT/src/util/$f.cpp" -o "$OUT/obj/util/$(echo "$f" | tr / _).o"
done
"$CC" "${FLAGS[@]}" -c "$DXMT/src/util/sha1/sha1.c" -o "$OUT/obj/util/sha1.o"
"$CXX" -std=c++20 "${FLAGS[@]}" -c "$DXMT/src/dxmt/dxmt_format.cpp" -o "$OUT/obj/dxmt/dxmt_format.o"
"$MINGW/arm64ec-w64-mingw32-windres" -i "$DXMT/src/dxgi/version.rc" -o "$OUT/obj/dxgi/version_res.o"
"$CXX" -shared -static -Wl,--file-alignment=4096 -o "$OUT/dxgi.dll" \
    "$OUT"/obj/dxgi/*.o "$OUT"/obj/util/*.o "$OUT"/obj/dxmt/*.o "$DXMT/src/dxgi/dxgi.def" \
    -L"$OUT/obj" -lwinemetal -lgdi32 -lntdll

for f in madeira_d3d12.dll d3d12.dll dcomp.dll dxgi.dll; do
    echo "  $f $(wc -c < "$OUT/$f") bytes"
done
