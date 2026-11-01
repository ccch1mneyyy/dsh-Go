#!/usr/bin/env bash
# 默认只配置；显式build才编译。输出独立，不修改App或设备。
set -euo pipefail
if [[ $# -ne 5 || ( "$5" != configure && "$5" != build ) ]]; then
  echo '用法：replay.sh NODE_SOURCE LINUX_OHOS_LLVM PYTHON OUTPUT configure|build' >&2
  exit 2
fi
recipe="$(cd -- "$(dirname -- "$0")" && pwd)"
source_root="$(cd -- "$1" && pwd)"
llvm_root="$(cd -- "$2" && pwd)"
python_bin="$(realpath -- "$3")"
mkdir -p -- "$4"
output="$(cd -- "$4" && pwd)"
export PATH="$(dirname -- "$python_bin"):$llvm_root/bin:$PATH"
export PYTHONDONTWRITEBYTECODE=1
export TMPDIR="$output/tmp" XDG_CACHE_HOME="$output/cache" CCACHE_DIR="$output/cache/ccache"
mkdir -p -- "$TMPDIR" "$XDG_CACHE_HOME"
export CC="$llvm_root/bin/aarch64-unknown-linux-ohos-clang -fno-emulated-tls"
export CXX="$llvm_root/bin/aarch64-unknown-linux-ohos-clang++ -fno-emulated-tls"
export CC_host="$llvm_root/bin/clang" CXX_host="$llvm_root/bin/clang++"
export CFLAGS='-DNDEBUG -Wno-error=implicit-function-declaration'
export CXXFLAGS='-DNDEBUG -Wno-error=implicit-function-declaration'
"$python_bin" "$recipe/prepare.py" --source "$source_root"
cd -- "$source_root"
"$python_bin" configure.py --dest-cpu=arm64 --dest-os=openharmony --cross-compiling --openssl-no-asm --shared --experimental-enable-pointer-compression -Dv8_enable_drumbrake=1 --prefix="$output/install"
"$python_bin" "$recipe/verify-config.py" --config config.gypi
"$python_bin" "$recipe/normalize-builtins.py" --source "$source_root"
cp config.gypi "$output/config.gypi"
if [[ "$5" = configure ]]; then echo '配置与内置JS检查完成；未运行make。'; exit 0; fi
make -C out BUILDTYPE=Release --jobserver-style=pipe -j"${MAKE_JOBS:-4}" "CXX.host=$llvm_root/bin/clang++" "CC.host=$llvm_root/bin/clang" 'LDFLAGS.host=-Wl,--no-as-needed -latomic -Wl,--as-needed' libnode
mkdir -p "$output/install/lib"
cp out/Release/libnode.so "$output/install/lib/libnode.so"
"$llvm_root/bin/llvm-readelf" -h -d "$output/install/lib/libnode.so" > "$output/elf.txt"
grep -Eq 'Machine: *AArch64' "$output/elf.txt"
grep -Fq 'Library soname: [libnode.so]' "$output/elf.txt"
sha256sum "$output/install/lib/libnode.so" > "$output/library.sha256"
echo '构建结束；仍需独立真机验收，不代表功能通过。'
