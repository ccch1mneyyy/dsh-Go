# M3-1：宿主内的原子独占发布接缝

**未在真机核实。** 这一目录的 Node runner 是 M3-1 的新原生组成部分，不代表旧 O7c 的 Ark 宿主候选已经通过，也不包含 ArkTS 接口、应用单次启动保护和 ready 通道。`c0949d6` 尚无这些文件，因此本补丁添加最小 Node runner；后续 O7c 应在这个 CMake target 上添加 Ark shim，不能再用旧候选覆盖它。

## 选择与接口

本次选择自己的 `libdsh_node_runner.so`，不修改上游 `node-addon-system`。`dsh_node_start` 由 Ark 侧单次启动保护通过后调用，在 `node::Start` 前注册 `dsh_ohos_publication`；库驻留到应用退出。JS 使用固定 Node 24.22.1 的 `process._linkedBinding('dsh_ohos_publication')`。这是 Node 的 linked 模块查找入口，不要求 `--expose-internals`，但它不是跨 Node 版本不变的公共 JavaScript API；版本锁与启动检查仍必要。

唯一函数 `renameNoReplace(temporaryPath, finalPath)` 同步调用 `renameat2(AT_FDCWD, ..., AT_FDCWD, ..., RENAME_NOREPLACE)`。成功返回 `undefined`。失败保留 `code`、负的原始 `errno` 与 `syscall: 'renameat2'`，不在错误消息中拼路径。原生层不复制、不 fsync、不清理文件，也不进行回退；JS 发布协议负责这些步骤。目标文件存在时必须保留两边原样，不能改用普通 `rename`。编译环境缺少 `SYS_renameat2` 时明确返回 `ENOSYS`，不能把它解释成允许回退。

Node-API 用版本 8。固定 Node 源中 `src/node_version.h` 的默认模块 API 也是 8；`src/node_api.cc` 将旧式 `napi_module` 转为 context-aware Node descriptor；`src/node_binding.cc` 在 Node 初始化之前把它登记到 linked 列表。`NAPI_MODULE_X` 在该版本忽略 flags，不能用它假装完成 linked 注册。本实现有意使用仍导出的 `napi_module_register`，其弃用状态和固定版本依赖是已知代价；当前 `node::Start` 接缝没有可直接传给 `node::AddLinkedBinding(Environment*, ...)` 的 Environment。不能把初始化后调用旧登记函数当成等价方案。

## 已实际验证的范围

固定官方 Linux x64 Node 24.22.1，源归档 SHA256 `4f5379796280cdaeb0c2f358fd04b6a16cc4fb7dfa83b5a8c91a9d963b435231`。原生函数在 Linux 编成测试 `.node`，另外编成仅供测试的预启动 `.so`，通过 `LD_PRELOAD` 在 Node 初始化前登记。后者用于验证真实 linked 注册；它不是产品启动方案，不能放进 HAP。

`publication-linked-probe.mjs` 在 JIT 和 O0 严格仿真下都实际成功：主 isolate 与文件型 ESM worker 均查到同一个模块接口；中文、emoji 路径成功提交；已存在的目标返回 `EEXIST` 且原目标和临时文件不变。严格仿真禁止全部动态 addon、禁 spawn/link、无 WebAssembly；linked 调用不依赖动态 addon 白名单。Linux 测试所在文件系统 `statfs.type=2035054128`，不能推及手机应用数据目录。

首轮 native 编译因局部变量重名失败，已修复，原日志保留。首轮测试用 CommonJS `eval` worker，观察到该 worker 没有重建 `--import` 仿真标记，严格断言失败；随后改为与当前 O4 一致的文件型 ESM worker，断言不变并通过。旧测试和失败日志保留，不能将后者的通过冒充前者已经验证。

手工相对路径编译与脚本绝对路径编译还暴露了 `__FILE__` 进入注册 descriptor 的构建差异。随后只将该字段改为固定仓库相对文件名；旧两套二进制及其既有实验哈希保留。规范脚本连续重建的 `.node` SHA256 均为 `2870d10332dd2bdb34102ac35de8d8e423592017cf4889a190ecf08ee941e823`，linked 测试 `.so` 均为 `8c0813da5e0773ecab3233565fdf023cda516e496149c837621350f3a8851797`；两套产物逐字节相同。最终源码 SHA256 `454e3b58be5ff23f20ca2b901d306330810df955219329dc841c3afe44f3c420` 已再次完成上述 JIT/严格探针。这个重建结论只覆盖本 Linux 编译环境，不是 OpenHarmony 交叉产物复现证明。

## 生成与执行

原生源码补丁可应用于 `c0949d6`，但下面的严格仿真命令**要求先合入 23 号 M3-3 主包的新版 `sim/preload.mjs` 与 marker**；不能用 c094 原有的环境变量门控预加载器代替。主代理的实际严格实验使用已审 `work-approved` 中的新版 preload。`--strict` 会在主 isolate 和文件型 worker 分别核实 marker、无 WebAssembly，以及 spawn/link/dlopen 的明确拒绝，缺少任一约束都会失败。只加 `--jitless` 不能算严格仿真。

在仓库根目录，用已核哈希的 Linux Node 分发目录作为第一参数：

```sh
bash runtime/tests/ohos/build-publication-native.sh "$NODE24_ROOT" out/publication-linux
LD_PRELOAD="$PWD/out/publication-linux/libpublication-test-linked.so" \
  "$NODE24_ROOT/bin/node" runtime/tests/ohos/publication-linked-probe.mjs
DSH_GO_OHOS_SIM_PLATFORM=openharmony DSH_GO_OHOS_SIM_ADDONS='[]' \
  LD_PRELOAD="$PWD/out/publication-linux/libpublication-test-linked.so" \
  "$NODE24_ROOT/bin/node" --jitless --import ./runtime/ohos/sim/preload.mjs \
  runtime/tests/ohos/publication-linked-probe.mjs --strict
```

原生 v1 候选 `c31270dd…` 的代码函数没有因此改变；独审指出该候选没有写出 M3-3 的测试前置，且探针只比较主/worker 标记是否相等，二者都 false 也能通过。v2 保留旧候选与反例，并添加上述强制断言；不能将旧候选在干净 c094 上的 jitless 结果误称严格通过。最终 C++ 源码和两种测试原生二进制哈希保持不变。

产品构建只接受 OHOS CMake toolchain、O7b 固定源码与目标 `libnode.so`。目标 SDK 尚不可用，CMake 链接、arm64 ABI、Ark/Node 符号隔离、HAP 签名与实机加载全部 `NOT_RUN`。尤其 `RTLD_LOCAL`、翻译单元分离和 `-Bsymbolic-functions` 都不能单独证明两套 `napi_*` 在目标 loader 中不会误绑定。

## 设备核验与结论边界

设备上必须分别验证：实际 `renameat2` 系统调用是否放行；应用数据所在文件系统是否支持 `RENAME_NOREPLACE`；已有文件/目录/悬空链接不被覆盖；两个并发发布者至多一个成功；写中、fsync 后、改名后杀进程并重启；真正原生错误码 `EINVAL` 才进入经说明的旧回退分支。普通 `rename()` 成功不能证明 `renameat2` 放行：固定 OpenHarmony 6.1 musl 的 arm64 分支可使用 `renameat`（38），而 `renameat2` 是另一个系统调用（276）。

文件 fsync 后的 SIGKILL 实验只检验进程终止前后的文件可见性。它不包含突然断电的目录项持久性证明。临时文件的创建与持久归属登记之间仍有崩溃窗口，未确认归属的残留不能按前缀删除；这部分须由上层登记/恢复协议明确限制，不能借原子改名宣称已完全解决。

## 源依据

- [Node 24.22.1 固定源码](https://nodejs.org/dist/v24.22.1/node-v24.22.1.tar.xz)：`src/node_api.cc`、`src/node_api.h`、`src/node_binding.cc`、`src/node.h`、`src/node_version.h`；交付证据记录逐文件哈希，不随包放上游归档。
- [Linux rename(2)](https://man7.org/linux/man-pages/man2/rename.2.html)：不覆盖标志、已有目标、文件系统支持和错误码。
- [Linux fsync(2)](https://man7.org/linux/man-pages/man2/fsync.2.html)：文件同步与目录同步的区别。
- [OpenHarmony 6.1 musl rename.c](https://raw.githubusercontent.com/openharmony/third_party_musl/OpenHarmony-v6.1-Release/src/stdio/rename.c) 与 [aarch64 syscall 头](https://raw.githubusercontent.com/openharmony/third_party_musl/OpenHarmony-v6.1-Release/arch/aarch64/bits/syscall.h.in)：这里只作为固定分支源分析，不作实际设备 allowlist 的证明。
