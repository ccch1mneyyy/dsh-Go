#!/usr/bin/env bash
# 固定源码与D盘隔离工具构建共享Node，不改系统保护或运行设备程序。
set -euo pipefail
BUILD_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
NODE_SOURCE="$BUILD_ROOT/node-v24.2.0"
LLVM_ROOT="$BUILD_ROOT/linux-tools/llvm19/llvm"
PYTHON_BIN="$BUILD_ROOT/linux-tools/python/bin"
export PATH="$PYTHON_BIN:$LLVM_ROOT/bin:$PATH"
export LD_LIBRARY_PATH="$BUILD_ROOT/linux-tools/compat/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"
export TMPDIR="$BUILD_ROOT/tmp"
export XDG_CACHE_HOME="$BUILD_ROOT/cache"
export CCACHE_DIR="$BUILD_ROOT/cache/ccache"
export PYTHONDONTWRITEBYTECODE=1
mkdir -p "$TMPDIR" "$XDG_CACHE_HOME"
export CC="$LLVM_ROOT/bin/aarch64-unknown-linux-ohos-clang -fno-emulated-tls"
export CXX="$LLVM_ROOT/bin/aarch64-unknown-linux-ohos-clang++ -fno-emulated-tls"
export CC_host=gcc
export CXX_host=g++
export CFLAGS='-DNDEBUG -Wno-error=implicit-function-declaration'
export CXXFLAGS='-DNDEBUG -Wno-error=implicit-function-declaration'
export MAKE_JOBS="${MAKE_JOBS:-4}"
test "$(git -C "$NODE_SOURCE" rev-parse HEAD)" = '591ba692bfe30408e6a67397e7d18bfa1b9c3561'
"$PYTHON_BIN/python3.13" --version
"$LLVM_ROOT/bin/aarch64-unknown-linux-ohos-clang" --version
gcc --version | head -1
make --version | head -1
cd "$NODE_SOURCE"
if [[ "${SKIP_CONFIGURE:-0}" != 1 ]]; then
  ./configure --dest-cpu=arm64 --dest-os=openharmony --cross-compiling --openssl-no-asm --shared --prefix="$BUILD_ROOT/install/node-v24.2.0-ohos-shared"
fi
python3 "$BUILD_ROOT/normalize-builtin-inputs.py"
make --jobserver-style=pipe -j"$MAKE_JOBS"
if [[ "${RUNTIME_LIBRARY_ONLY:-0}" = 1 ]]; then
  cp -p out/Release/libnode.so.137 "$BUILD_ROOT/install/node-v24.2.0-ohos-shared/lib/libnode.so.137"
else
  make --jobserver-style=pipe install
fi
printf '%s\n' '完整共享Node构建与安装完成，产物仅在D盘，尚未设备验证。'
