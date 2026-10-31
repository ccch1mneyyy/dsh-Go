# 鸿蒙本机引擎的 Node 运行库构建材料

本目录记录鸿蒙 HAP 内 `libnode.so` 的可复现构建材料与取舍。运行库本身不进仓库（151 MB），
只保留补丁、脚本与验证口径，任何人都能按同样的源码和参数重建。

## 为什么需要补丁

HarmonyOS 第三方应用不允许 JIT，运行库以 `--jitless` 启动。该模式下 V8 不提供
`WebAssembly` 全局对象（是 `ReferenceError: WebAssembly is not defined`，不是编译失败）。

Node v24.2.0 的内置 undici 在 **模块加载时** 立即初始化 llhttp 的 wasm：

```js
// deps/undici/undici.js:6429（未修补）
var llhttpPromise = lazyllhttp();   // 顶层调用
llhttpPromise.catch();
```

于是任何 `import` 到内置 undici client 的路径都会在 `--jitless` 下抛错，设备侧表现为
`NODE_INTERNAL_DEPS_UNDICI_UNDICI_L6340`。上游后续版本把这次初始化改成了惰性；本补丁在
v24.2.0 上做等价改动，不改变 fetch 语义、不替换全局 fetch、不启用 JIT。

补丁见 [`undici-lazy-llhttp.patch`](undici-lazy-llhttp.patch)：把顶层调用包成 `ensureLlhttp()`，
只在真正建立 HTTP/1.1 连接时初始化。需要 wasm 的路径仍会在那时失败，但 DSH 的
`web` 启动、令牌交换与 `session/list` 都不走 wasm。

## 构建步骤

固定源码：Node v24.2.0，commit `591ba692bfe30408e6a67397e7d18bfa1b9c3561`。
工具链：官方 OpenHarmony Windows CLT 26.0.0.851（LLVM 19.1.7，target `aarch64-linux-ohos`）。

1. 在构建根目录放 `node-v24.2.0/`（上述 commit）、`linux-tools/llvm19/llvm`（CLT 的 llvm）、
   `linux-tools/python` 与 `linux-tools/compat`。脚本通过 `BUILD_ROOT=$(dirname $0)` 定位它们。
2. 应用补丁：`patch -p1 -d node-v24.2.0 < undici-lazy-llhttp.patch`。
3. `bash build-shared-node.sh`（首次会执行 configure）：

   ```text
   ./configure --dest-cpu=arm64 --dest-os=openharmony --cross-compiling \
     --openssl-no-asm --shared --prefix=<build-root>/install/node-v24.2.0-ohos-shared
   ```

4. `bash build-shared-node-v3.sh`：**先**跑 `normalize-builtin-inputs.py`，再 `make`。
   这一步不可省略——Windows 检出会把内置 JS 变成 CRLF，js2c 记录的字节数与 V8 raw literal
   实际 LF 长度不一致，真机会报 `Invalid or unexpected token` 并在错误路径上触发 SIGSEGV。
   脚本只规范 `out/libnode.target.mk` 里 js2c 真实依赖的 JS/MJS 输入，不做全树替换。
5. `python3 align-libnode-soname.py && bash build-shared-node-soname.sh`：把链接目标与
   SONAME 从 `libnode.so.137` 对齐为 `libnode.so`，与 HAP 内签名库和 addon 的 `DT_NEEDED`
   一致，只重链接、不重编对象。

产物：`node-v24.2.0/out/Release/libnode.so`（ELF64、AArch64、DYN，SONAME `libnode.so`，
NEEDED `libc++_shared.so`、`libc.so`）。hvigor 在打包时会 `DoNativeStrip`，HAP 内体积约 127 MB。

## 验证口径

真机（MatePad Pro，API 26）分阶段探针，六阶段全部通过后才算本机引擎可用：

| 阶段 | 判据 |
| --- | --- |
| signed-require | `SIGNED_LIBRARY_API_OK`，`nativeLoaded`、`dshInternalInterfaces` |
| signed-flock | `exclusiveLock`、`closeReleasesLock` |
| install | `ASSETS_READY`，14585 文件全摘要、12 命令入口、`relativeSymlinks=0` |
| platform-addon | `PLATFORM_ADDON_OK`，`originalLoaderSelectedSigned` |
| platform-flock | `PLATFORM_FLOCK_OK`，`publicFlockApiVerified` |
| dsh | `SESSION_LIST_OK`，`tokenExchange=true`、`sessionList=true`、`modelRequestSent=false` |

第 6 阶段只验证 `dsh web` 的启动、令牌交换与只读 `session/list`：不发模型请求、不读用户
Key 或历史会话。基础探针通过不等于 DSH 通过，加载成功不等于功能通过。

## 已知边界

- HAP 内缓存 `.node` 路径加载仍然失败；平台扩展走原 loader 的 optional-package 机制加载
  HAP 内签名 `.so`，不宣称任意动态插件可用。
- `COMMAND-ENTRIES.json` 只解析并校验 12 个命令入口目标，命令调度尚未消费该映射，
  PATH/npm-bin 行为不等价。
- 未验证 HTTPS、真实模型回复、持久化启停；这些不在本构建材料的结论范围内。
