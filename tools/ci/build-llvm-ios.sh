#!/bin/bash
# LLVM 15.0.7 static libraries for iOS arm64, as build/dxmt-ios/build.sh expects
# them (docs/BUILDING.md, build/dxmt-ios/README.md step 3):
#   toolchains/llvm-project/      source (only llvm/include is read afterwards)
#   toolchains/llvm-host-build/   host llvm-tblgen
#   toolchains/llvm-ios-build/    include/ + lib/libLLVM*.a for iOS
set -euo pipefail
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$R/toolchains"
SRC="$T/llvm-project"
HOST="$T/llvm-host-build"
IOS="$T/llvm-ios-build"
JOBS="$(sysctl -n hw.ncpu)"

if [ ! -d "$SRC/llvm" ]; then
    git clone --depth 1 --branch llvmorg-15.0.7 https://github.com/llvm/llvm-project.git "$SRC"
fi

# Apple ld has no --gc-sections; AddLLVM.cmake only uses -dead_strip for "Darwin".
ADD="$SRC/llvm/cmake/modules/AddLLVM.cmake"
if ! grep -q 'MATCHES "Darwin|iOS"' "$ADD"; then
    # Line 266 in 15.0.7: the condition right above "ld64's implementation of -dead_strip".
    sed -n '267p' "$ADD" | grep -q 'dead_strip' || { echo "AddLLVM.cmake layout changed" >&2; exit 1; }
    sed -i '' '266s/MATCHES "Darwin"/MATCHES "Darwin|iOS"/' "$ADD"
fi
grep -n 'MATCHES "Darwin' "$ADD" | head -5

if [ ! -x "$HOST/bin/llvm-tblgen" ]; then
    cmake -S "$SRC/llvm" -B "$HOST" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DLLVM_TARGETS_TO_BUILD= -DLLVM_ENABLE_PROJECTS= -DLLVM_INCLUDE_TESTS=Off \
        -DLLVM_INCLUDE_BENCHMARKS=Off -DLLVM_INCLUDE_EXAMPLES=Off -DLLVM_ENABLE_ZLIB=Off \
        -DLLVM_ENABLE_ZSTD=Off -DLLVM_ENABLE_TERMINFO=Off -DLLVM_ENABLE_LIBXML2=Off
    ninja -C "$HOST" -j "$JOBS" llvm-tblgen
fi

cmake -S "$SRC/llvm" -B "$IOS" -G Ninja \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_HOST_TRIPLE=arm64-apple-ios17.0 -DLLVM_DEFAULT_TARGET_TRIPLE=arm64-apple-ios17.0 \
    -DLLVM_TARGET_ARCH=host -DLLVM_TARGETS_TO_BUILD= -DLLVM_ENABLE_PROJECTS= \
    -DLLVM_BUILD_TOOLS=Off -DLLVM_BUILD_UTILS=Off -DLLVM_INCLUDE_TOOLS=Off -DLLVM_INCLUDE_UTILS=Off \
    -DLLVM_INCLUDE_TESTS=Off -DLLVM_INCLUDE_BENCHMARKS=Off -DLLVM_INCLUDE_EXAMPLES=Off \
    -DLLVM_INCLUDE_DOCS=Off -DLLVM_ENABLE_BINDINGS=Off \
    -DLLVM_ENABLE_ZLIB=Off -DLLVM_ENABLE_ZSTD=Off -DLLVM_ENABLE_TERMINFO=Off -DLLVM_ENABLE_LIBXML2=Off \
    -DLLVM_TABLEGEN="$HOST/bin/llvm-tblgen" \
    -DCMAKE_CXX_FLAGS="-include cstdint"
ninja -C "$IOS" -j "$JOBS"
ls "$IOS/lib/"libLLVM*.a | wc -l
du -sh "$IOS/lib"
