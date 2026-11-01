#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
: "${OHOS_TEST_PROCESS_PREFIX:?指定仅应用 OHOS 进程补丁的独立 DSH 前缀}"
: "${OHOS_TEST_BASE_PREFIX:?指定未修改的 npm-ci DSH 前缀}"
: "${OHOS_SIM_PRELOAD:?指定已通过复核的 O0 sim/preload.mjs}"
node_bin=${NODE:-node}
"$node_bin" -e 'if (process.version !== "v24.22.1") throw new Error("本轮测量固定 Node 24.22.1")'
env -u DSH_GO_OHOS_SIM "$node_bin" --test --test-isolation=none "$repo/runtime/tests/ohos/process-android-path.test.mjs"
tests=("$repo/runtime/tests/ohos/process.test.mjs" "$repo/runtime/tests/ohos/process-integration.test.mjs" "$repo/runtime/tests/ohos/process-policy.test.mjs")
DSH_GO_OHOS_SIM=1 "$node_bin" --test --test-isolation=none "${tests[@]}"
DSH_GO_OHOS_SIM=1 "$node_bin" --jitless --import "$OHOS_SIM_PRELOAD" --test --test-isolation=none "${tests[@]}"
