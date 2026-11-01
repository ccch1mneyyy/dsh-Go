#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 2 ]]; then
  printf 'Usage: %s NODE_24_22_1_ROOT OUTPUT_DIRECTORY\n' "$0" >&2
  exit 2
fi
node_root=$(cd "$1" && pwd)
output=$(mkdir -p "$2" && cd "$2" && pwd)
root=$(cd "$(dirname "$0")/../../.." && pwd)
[[ $("$node_root/bin/node" --version) == v24.22.1 ]] || {
  printf 'This Linux fixture requires Node 24.22.1\n' >&2
  exit 2
}
[[ $(uname -s) == Linux ]] || { printf 'Linux fixture only\n' >&2; exit 2; }
common=(-std=c++20 -shared -fPIC -fvisibility=hidden -DNAPI_VERSION=8
  -I "$node_root/include/node" "$root/runtime/ohos/host/publication_binding.cc")
"${CXX:-c++}" "${common[@]}" -DDSH_PUBLICATION_TEST_ADDON -o "$output/publication.node"
"${CXX:-c++}" "${common[@]}" -DDSH_PUBLICATION_TEST_PRELOAD -o "$output/libpublication-test-linked.so"
sha256sum "$node_root/bin/node" "$root/runtime/ohos/host/publication_binding.cc" \
  "$output/publication.node" "$output/libpublication-test-linked.so" > "$output/SHA256.txt"
printf 'Built Linux test fixtures only; these binaries must not be shipped in an OHOS HAP.\n'
