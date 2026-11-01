#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo 'usage: NODE=/path/to/node24.22.1 [DSH_OHOS_PREFIX=/prepared/prefix] bash runtime/ohos/sim/measure.sh NEW_OUTPUT_DIR [round options]' >&2
  exit 2
fi
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/../../.." && pwd)"
node_bin="${NODE:-node}"
if [[ "$("$node_bin" --version)" != v24.22.1 ]]; then
  echo 'This measurement requires the pinned Node v24.22.1.' >&2
  exit 2
fi
case_root="$1"
shift
mkdir -- "$case_root"
case_root="$(cd -- "$case_root" && pwd)"
prefix="${DSH_OHOS_PREFIX:-$case_root/prefix}"
if [[ -z "${DSH_OHOS_PREFIX:-}" ]]; then
  mkdir -- "$prefix"
  cp -- "$repo_root/runtime/locks/dsh-0.2.1-rc.4/package.json" "$prefix/package.json"
  cp -- "$repo_root/runtime/locks/dsh-0.2.1-rc.4/package-lock.json" "$prefix/package-lock.json"
  node_path="$(command -v -- "$node_bin")"
  PATH="$(dirname -- "$node_path"):$PATH" npm ci --prefix "$prefix" --ignore-scripts --no-audit --no-fund
  python3 "$repo_root/runtime/lib/rtbuild.py" patch-dsh --prefix "$prefix" --dsh-version 0.2.1-rc.4 --out "$case_root/patches.json"
fi
result=0
for mode in jit jitless sim; do
  options=()
  if [[ "$mode" == sim ]]; then options+=(--platform); fi
  "$node_bin" "$script_dir/round.mjs" --prefix "$prefix" --out "$case_root/$mode" --mode "$mode" "${options[@]}" "$@" || result=1
done
exit "$result"
