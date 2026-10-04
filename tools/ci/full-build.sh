#!/bin/bash
# Build Madeira's app executable from a clean checkout on a GitHub macOS runner,
# one stage per call, in the order docs/BUILDING.md gives:
#
#   toolchains gnutls ffmpeg freetype wine-macos wine-arm64ec
#   ntdll win32u wineserver fex dxmt app ipa
#
# The resources the bundle carries prebuilt (the i386 farm, dockhost.exe, the
# Visual C++ runtime folder, prefix template, ...) are not rebuilt: "ipa" puts
# the new executable into the official IPA of the same version instead.
# Stages that docs/BUILDING.md marks UNVERIFIED from clean are reconstructed
# here; every guess is commented where it is made.
set -euo pipefail
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$R"
JOBS="$(sysctl -n hw.ncpu)"
MINGW_NAME=llvm-mingw-20260421-ucrt-macos-universal
MINGW="$R/toolchains/$MINGW_NAME/bin"
BREW="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
export PATH="$BREW/opt/bison/bin:$BREW/opt/flex/bin:$PATH"

show_errs() {   # print the per-file .err logs a build script left behind
    local dir="$1"
    for f in "$dir"/*.err "$dir"/err-*.txt; do
        [ -s "$f" ] || continue
        if grep -q "error:" "$f"; then echo "----- $f"; grep -m 20 "error:" "$f"; fi
    done
}

stage="$1"
echo "=== stage: $stage ==="
case "$stage" in
toolchains)
    brew install bison flex ninja meson ccache pkgconf sevenzip >/dev/null
    if [ ! -x "$MINGW/arm64ec-w64-mingw32-clang" ]; then
        mkdir -p toolchains
        curl -fsSL "https://github.com/mstorsjo/llvm-mingw/releases/download/20260421/$MINGW_NAME.tar.xz" \
            | tar -xJ -C toolchains
    fi
    xcodebuild -downloadComponent MetalToolchain || echo "MetalToolchain download failed (continuing)"
    xcrun --sdk iphoneos --show-sdk-path
    ;;
gnutls)
    bash build/gnutls-ios/build.sh
    ls toolchains/gnutls-ios/include/gnutls/gnutls.h
    ;;
ffmpeg)
    bash build/ffmpeg/build.sh
    ;;
freetype)
    [ -d research/freetype ] || git clone --depth 1 --branch VER-2-13-3 https://github.com/freetype/freetype.git research/freetype
    bash build/freetype-ios/build.sh
    ;;
wine-macos)
    # build/dxmt-ios/README.md: "Wine aarch64-windows static libs already built in
    # wine/build-macos". The unix-side builds only read its include/config.h and
    # generated headers, so configure + the include directory is enough.
    mkdir -p wine/build-macos && cd wine/build-macos
    [ -f config.status ] || PATH="$MINGW:$PATH" ../configure --enable-archs=aarch64 --without-x --disable-tests \
        || { tail -50 config.log; exit 1; }
    PATH="$MINGW:$PATH" make -j"$JOBS" include
    ls include/config.h
    ;;
wine-arm64ec)
    # Same configure as build/wine-pe/build-ntdll.sh; only its generated headers
    # (dwrite.h, mfobjects.h, ...) are used here.
    mkdir -p wine/build-arm64ec && cd wine/build-arm64ec
    [ -f config.status ] || PATH="$MINGW:$PATH" ../configure --enable-archs=arm64ec --without-x --disable-tests --enable-winegstreamer \
        || { tail -50 config.log; exit 1; }
    PATH="$MINGW:$PATH" make -j"$JOBS" include
    ;;
ntdll)
    bash build/ntdll-unix/build.sh || { show_errs build/ntdll-unix/obj; exit 1; }
    show_errs build/ntdll-unix/obj
    ;;
win32u)
    bash build/win32u-unix/build.sh || { show_errs build/win32u-unix/obj; exit 1; }
    ;;
wineserver)
    bash tools/ci/wineserver-base.sh
    PATH="$MINGW:$PATH" bash build/wineserver/build.sh || { show_errs build/wineserver/obj; exit 1; }
    ;;
fex)
    bash build/fex-ios/build.sh
    ;;
dxmt)
    bash build/dxmt-ios/build.sh || { show_errs build/dxmt-ios/obj; exit 1; }
    # The app links libdxmt_combined.a: this unix side plus the LLVM archives airconv
    # needs. build.sh only refreshes an existing one, so make it from scratch.
    libtool -static -o build/dxmt-ios/libdxmt_combined.a build/dxmt-ios/libdxmt_unix.a \
        toolchains/llvm-ios-build/lib/libLLVM*.a 2> >(grep -v "has no symbols\|same member name" >&2)
    cp build/dxmt-ios/libdxmt_combined.a app/Madeira/libdxmt_combined.a
    ls -l app/Madeira/libdxmt_combined.a
    ;;
app)
    bash build/stage-licenses.sh
    mkdir -p app/Madeira/x86_64-vcruntime
    # The project has no shared scheme, so build the target (Debug: the
    # configuration docs/BUILDING.md says runs the games).
    xcodebuild -project app/Madeira.xcodeproj -target Madeira -configuration Debug -sdk iphoneos \
        SYMROOT="$R/build/xcode-out" OBJROOT="$R/build/xcode-obj" \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM= \
        build 2>&1 | tee build/xcodebuild.log | grep -E "error:|Undefined symbols|duplicate symbol|BUILD (SUCCEEDED|FAILED)" | head -200 || true
    grep -q "BUILD SUCCEEDED" build/xcodebuild.log
    ls -l build/xcode-out/Debug-iphoneos/Madeira.app/Madeira*
    ;;
ipa)
    # $2: official IPA of the same version, $3: output IPA, $4: dir with replacement DLLs
    BASE="$2"; OUT="$3"; DLLS="${4:-}"
    APP=build/xcode-out/Debug-iphoneos/Madeira.app
    STAGE="$(mktemp -d)"
    cp "$BASE" "$OUT"
    mkdir -p "$STAGE/Payload/Madeira.app/arm64ec-windows"
    for f in Madeira Madeira.debug.dylib __preview.dylib; do
        [ -f "$APP/$f" ] && cp "$APP/$f" "$STAGE/Payload/Madeira.app/$f"
    done
    if [ -n "$DLLS" ]; then cp "$DLLS"/*.dll "$STAGE/Payload/Madeira.app/arm64ec-windows/"; fi
    (cd "$STAGE" && zip -q -r "$R/$OUT" Payload)
    unzip -l "$OUT" | grep -E "Madeira.app/(Madeira|Madeira.debug.dylib|__preview.dylib)$|arm64ec-windows/(dcomp|dxgi|d3d12|madeira_d3d12)\.dll"
    ;;
*)
    echo "unknown stage $stage" >&2; exit 2 ;;
esac
echo "=== stage $stage done ==="
