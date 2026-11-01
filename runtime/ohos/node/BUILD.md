# O7b：鸿蒙专用 libnode.so 的可复现构建入口

**未在真机核实；OpenHarmony 目标编译、HAP 装载和库体积测量均为 NOT_RUN。** 本包已核对固定 Node 源码、实际应用源码补丁、运行平台分支检查和缺失 SDK 的失败路径。不能以这些结果替代目标编译。

## 固定输入

Node 必须为 **24.22.1**，源归档为 [node-v24.22.1.tar.xz](https://nodejs.org/dist/v24.22.1/node-v24.22.1.tar.xz)。官方 [SHASUMS256.txt](https://nodejs.org/dist/v24.22.1/SHASUMS256.txt) 列出的 SHA256 为 `4f5379796280cdaeb0c2f358fd04b6a16cc4fb7dfa83b5a8c91a9d963b435231`，脚本强制核验。

本次已实际取得该 **57669336 字节**源归档，实算 SHA256 与官方值一致；只提取所需源码以节省磁盘。从归档读出的四个待补丁文件与先前固定标签的参考文件摘要一致，随包 `source-archive.json` 记录这次核验。没有展开或编译完整源码树。

SDK 采用公开 OpenHarmony native SDK。选定候选为 [OpenHarmony 6.1 Release](https://gitcode.com/openharmony/docs/blob/master/zh-cn/release-notes/OpenHarmony-v6.1-release.md) 的公开 SDK 6.1.0.31 / API 23；使用 [官方发布目录](https://repo.huaweicloud.com/openharmony/os/6.1-Release/) 的 Linux SDK 及对应 `.sha256`。本次 GET 校验文件和 HEAD 归档的执行层请求都返回 HTTP 200、`text/html`、195 字节 `Site Unavailable`；目录显示的另一个 `/harmonyos/os/6.1-Release/` 路径结果相同。未取得有效官方 SDK 摘要。没有把下载错误页当作 SDK，也没有伪造库大小。

构建主机为 Linux，Python 3.12+、GNU make、GNU patch、可用的宿主 C/C++ 编译器以及官方 Node 24.22.1。Node 官方 [BUILDING.md](https://github.com/nodejs/node/blob/v24.22.1/BUILDING.md) 的 Linux GCC 下限为 12.2。SDK Clang 与宿主编译器分开设置；不让交叉编译器去产生构建时需要运行的宿主工具。构建工具 esbuild 固定为 0.27.3，由 O7a 的完整性锁安装。

## 执行

先应用 O7a，其 `patch-undici.mjs` 修复保持请求体的重定向中 multipart 边界错配；本包引用该已独立交付的构建入口，不再复制一份生成器。

```sh
npm ci --ignore-scripts --no-audit --no-fund --prefix runtime/ohos/node/build-tools

python3 runtime/tests/ohos/node-build.py --source /absolute/pristine-node-v24.22.1

python3 runtime/ohos/node/build-node.py \
  --sdk-native /absolute/sdk/native \
  --source-archive /absolute/node-v24.22.1.tar.xz \
  --host-node /absolute/node-v24.22.1-linux-x64/bin/node \
  --work /absolute/new-node-ohos-build \
  --output /absolute/new-node-ohos-artifacts \
  --jobs 4
```

`--work` 和 `--output` 必须是新目录。脚本在校验输入后创建它们，不删除旧构建；中断时保留 `build-plan.json`、工具链包装脚本和阶段日志。`configure.log` / `make.log` 给出实际编译失败点。本机可用 `build-plan.json` 中的精确环境和命令，在保留的源目录继续执行；不要未经核对就复用别的 Node/SDK 版本的构建缓存。

脚本先按归档实际成员大小检查解压空间，记录开始时的可用空间。对象文件与链接阶段的峰值磁盘/内存开销尚未测量；不提供一个虚构的资源保证。

## 产物与配置

| 项目 | 构建设置与核验 |
| --- | --- |
| 目标 | `--dest-os=openharmony --dest-cpu=arm64 --cross-compiling --shared` |
| 编译器 | SDK LLVM，`--target=aarch64-linux-ohos`，SDK sysroot；宿主 GCC 单独配置 |
| 默认执行 | `--v8-options=--jitless`，宿主启动参数再次固定 `--jitless` |
| Node 内置功能 | SQLite、zstd、OpenSSL 保留原来的静态内置配置，配置文件中断言其相关选项 |
| ICU | `small-icu`，`root,en`；Unicode 字符串和 UTF-8 文件名保留，完整的中文 Intl 本地化数据不是本构建的承诺 |
| 环境选项 | 禁用 `NODE_OPTIONS` 解析，宿主明确传 `--import`、`--expose-internals` 等固定参数 |
| Inspector | 禁用；本机引擎不开放调试端口 |
| 内置快照/代码缓存 | 交叉构建显式禁用；不禁止 O2 对用户模块启用 `module.enableCompileCache` |
| ELF | AArch64、ET_DYN、无 PT_INTERP，SONAME 必须为 `libnode.so` |
| C++ 运行库 | 让 SDK 目标编译器定位 `libc++_shared.so`，找不到则失败；随 HAP 一同分发 |

输出包括精简后的 `libnode.so`、`libc++_shared.so`、Node 合并许可证和 `build.json`。报告记录源码/补丁摘要、实际 SDK manifest、编译器摘要和版本、精确环境与命令、原始和精简库大小及摘要、ELF 动态信息。仅在构建真正完成后才产生这些大小。

Node 上游 [共享库说明](https://github.com/nodejs/node/blob/v24.22.1/doc/contributing/shared-library.md) 将共享库构建列为非正式支持方式，列出的已测试平台不包含 OpenHarmony。固定源码已包含 OpenHarmony 目标支持，也不等于本脚本的所有链接步骤已获设备验证。

## 四处固定源码变更及其依据

所有源码前后摘要在 `node24-ohos-pins.json`，源码 diff 在 `node24-ohos.diff`。它们只应用到本脚本新解压的鸿蒙构建树；没有接入 Android 构建入口。

1. **共享库命名。** [configure.py](https://github.com/nodejs/node/blob/v24.22.1/configure.py) 约 1849 行只对 Android 使用 `so`，其他 Linux 宿主目标会得到 `so.137`。为 OpenHarmony 也选择 `so`，让实际链接产物和 SONAME 都是 `libnode.so`，不靠重命名一个不同 SONAME 的库补救。
2. **完整关闭 io_uring 探测。** [libuv linux.c](https://github.com/nodejs/node/blob/v24.22.1/deps/uv/src/unix/linux.c) 的 `uv__use_io_uring` 在约 479 行，对非 SQPOLL 分支先返回 1，到约 489 行才读取 `UV_USE_IO_URING`。因此环境变量 0 不能覆盖该路径。仅当同时定义 `__OHOS__` 与 `DSH_GO_EMBEDDED_RUNTIME` 时，采用已有 Android 分支同样的直接返回 0，使用 epoll/线程池路径。手机 seccomp 行为仍须实测；不安装可能干扰 Ark 的 SIGSYS handler。
3. **保留宿主的进程设置。** [node.cc](https://github.com/nodejs/node/blob/v24.22.1/src/node.cc) 的专用分支调用初始化时传入 `kNoStdioInitialization`、`kNoDefaultSignalHandling`、`kNoAdjustResourceLimits`；这些标志来自该版本公开 `node.h`，分别避免 Node 接管已经由宿主处理的 stdio、信号和资源上限。其他初始化仍由 `node::Start` 完成。
4. **把正常 JS process.exit 限定到引擎结束。** 官方 [node.h](https://github.com/nodejs/node/blob/v24.22.1/src/node.h) 明确说明默认退出处理会调用进程级 `exit()`。在 `NodeMainInstance::Run` 的专用分支安装 `SetProcessExitHandler`，记录原退出码并 `Stop(env)`，随后不让空的 SpinEventLoop 返回值覆盖它。这是针对进程内嵌入的源码修复候选，尚未执行重编后的 Node。`process.abort()`、原生崩溃、OOM 等仍可能终止整个应用；线程不是故障隔离边界。

后三处仅在 **`__OHOS__ && DSH_GO_EMBEDDED_RUNTIME`** 同时成立时启用。针对真实固定源码，测试比较了去掉头文件包含后的预处理主体：Linux、Android，以及未开启专用宏的 OpenHarmony，修改前后逐字一致。Python 的命名分支也实测 Linux / Android / macOS 结果不变。此证据证明补丁选择边界，不证明目标二进制 ABI 或字节完全一致。

链接时给目标设置 `-Bsymbolic-functions`，让 Node 库内部函数优先绑定其自身定义；它不是已证实的 Node/Ark NAPI 隔离方案。Ark 的 `napi_*` 与 Node 的同名符号具有不同 env 语义，O3 原生 addon 的动态导入仍需独立验证，不能仅凭这个选项放行。

## 本机必须完成的验收

完整配置与链接、真实产物体积、`libnode.so` 和 `libc++_shared.so` 的 HAP 签名分发、Ark/Node 符号解析、首次/重复启动、内置 SQLite、zstd、TLS 证书校验、jitless 无 wasm、普通 `process.exit(7)` 返回退出码且应用存活、Node 退出后不能再次启动，全部在本次执行环境记为 **NOT_RUN**。最终内置 Fetch 的 multipart 测试必须去掉 O7a 的候选 bundle 替代加载，直接针对编入共享库的内置版本运行。
