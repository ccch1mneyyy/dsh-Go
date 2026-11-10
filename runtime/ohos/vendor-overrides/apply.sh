#!/bin/sh
# 把 vendor-overrides 里的最终字节覆盖到运行时树，覆盖前按 SHA256SUMS 校验来源。
# 用法: apply.sh /absolute/path/to/runtime/tree
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

if [ $# -ne 1 ]; then
  echo "usage: $0 <runtime-tree>" >&2
  exit 2
fi

tree=$1
if [ ! -d "$tree/node_modules/@deepseek-ai" ]; then
  echo "not a runtime tree: $tree" >&2
  exit 2
fi

cd "$here"
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum -c SHA256SUMS >/dev/null
else
  shasum -a 256 -c SHA256SUMS >/dev/null
fi

cp -R "$here/node_modules/." "$tree/node_modules/"

echo "applied $(find "$here/node_modules" -type f | wc -l | tr -d ' ') vendor override(s) to $tree"
