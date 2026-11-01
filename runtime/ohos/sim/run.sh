#!/usr/bin/env bash
set -euo pipefail
SIM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DSH_GO_OHOS_SIM=1
exec "${DSH_OHOS_NODE:-node}" --jitless --import "$SIM_DIR/preload.mjs" "$@"
