# M3-1：用不覆盖的原子改名发布附件与会话

## 本轮范围与未完成项

本候选把 OpenHarmony 两个 provider 的发布回退改为：在最终文件的**同一父目录**独占创建临时文件，逐块写完并执行文件 `fsync`，再调用自有 linked NAPI 模块的 `renameat2(..., RENAME_NOREPLACE)`。源文件只读打开，辅助函数不删除源文件；最终路径已存在时不覆盖。

本轮有真实 Linux 系统调用、两个实际 provider 辅助函数、外层附件/会话接口及 SIGKILL 后重试的证据。它尚不能被称为整个 M3-1 恢复任务完成：**生产 `installPublication()` 没有持久化临时文件登记；整个 App 在任意时刻被杀后的自动临时文件回收仍未完成。** 测试父进程预先持久登记的 receipt 只证明那个已登记区间可以按身份清理。创建成功到取得或持久登记身份之间留下的未知文件必须保留，不能通过文件名前缀或大小为零推定归属。

如果实际原生提交返回 `EINVAL`，按追加 7 的明确决定退回已有独占复制算法，同时发出 `OHOS_PUBLICATION_NONATOMIC_FALLBACK` 警告。此时半成品最终文件的风险仍然存在。本轮也真实重现该风险，没有将回退情形写为原子发布成功。

## 接线与前置条件

运行时固定为 Node **24.22.1**。自有宿主须在 Node 启动前注册名为 `dsh_ohos_publication` 的 linked NAPI 模块；该模块提供同步函数：

```js
renameNoReplace(absoluteTemporaryPath, absoluteFinalPath)
// 成功返回 undefined；失败抛带 code、errno、syscall 的系统错误。
```

原生函数只执行固定 `RENAME_NOREPLACE` 系统调用，不复制、不执行普通覆盖式 `rename`、不清理文件。本目录不实现或替代原生模块；其源码、构建与宿主注册由同一交付中的原生分项提供。Linux `.node` 或 `LD_PRELOAD` 测试库不是 OpenHarmony 产品二进制。

正式启动显式增加 `--import /绝对路径/runtime/ohos/publication/preload.mjs`，保持它为独立启动输入，不把它藏入网络预加载。预加载仅在 `process.platform === 'openharmony'` 或测试预加载明确设置 `globalThis[Symbol.for('dsh.go.ohos.sim')] === true` 时安装服务；不会读取旧仿真环境变量来启用产品分支。缺少 linked binding、成员不符或 Node 版本不符都明确失败，不静默退回旧算法。

服务注册在 `Symbol.for('dsh.go.ohos.publication')`，协议版本为 1，包含 `publish` 和只读 `pendingCount`。服务与同路径串行表属于一个主 Node 引擎。虚拟 shell 的 Worker 会继承 `--import` 参数；预加载在 Worker 中不安装该主引擎服务，也不使无关 Worker 启动失败。两个 provider 的新接缝在缺少服务时抛 `ERR_OHOS_PUBLICATION_PRELOAD_MISSING`。

新 vendor 文件为 `zzzzzzzz-ohos-atomic-publication.diff`，排序在原附件/会话补丁之后，仅登记在 schema 2 的 `targetSets.ohos`。Android 集合及其原始 11 个公共补丁内容不变。锁实现没有改动。

## 发布顺序与不变量

1. 对同一最终绝对路径排队。不同路径可独立发布。
2. 先沿用硬链接路径。只有 `EACCES`、`EPERM`、`EXDEV`、`ENOTSUP` 或 `EMLINK` 才进入 OpenHarmony 复制路径；硬链接的 `EEXIST` 原样传播。
3. 用 `wx`、权限 `0600` 在最终路径的同一父目录分配唯一临时文件。候选名字在打开前排除原源路径和最终路径。取得已打开文件的 `dev/ino` 身份，确认它是空的普通文件。
4. 每次最多读取 65,536 字节并写入临时文件，等待每次写入完成。写完执行临时文件的 `sync()`；取消发生在同步等待期间时，同步返回后再次检查取消状态，阻止后续提交。
5. 核对临时目录项仍指向登记的身份。在同一 JS turn 中立即同步调用原生 `renameNoReplace`。支持该操作的文件系统上，最终路径只有缺失或完整文件两种状态；已有空文件、普通文件、目录或符号链接均不得被覆盖。
6. 关闭本次打开的句柄，并只清理本调用明确登记的临时路径。成功改名后临时路径已经不存在，清理函数不会删除最终路径。若临时路径已被替换，拒绝删除替换者并保留错误。

临时身份检查与 `unlink` 不是内核提供的原子“仅匹配 inode 才删除”操作。本实现适用于主引擎管理的应用私有发布目录；同一个 JS turn 不代表能阻止任意其他原生进程在检查与删除之间替换路径。不能将此清理函数描述为面向任意不可信共享目录的通用原语。最终路径的不覆盖提交由 `RENAME_NOREPLACE` 本身保证。

源文件在复制期间应为 DSH 已有的不可变对象或已同步 staging 文件；本分项不新增对任意外部并发改写源文件的快照语义。附件 provider 原有的 staging 删除、摘要检查、只读权限与目录同步仍由原调用方执行；“辅助函数保留 source”不意味着改变原调用方成功后删除 staging 的行为。会话原来的 `rejectExistingLog` 也保持不变，历史遗留的半成品最终文件不会被这个新协议擅自删除。

## 错误与回退

| 出错位置/错误 | 行为 |
|---|---|
| 硬链接 `EEXIST` | 原样传播；不打开源文件进行复制 |
| 固定原生 `renameat2` 调用返回 `EINVAL` | 发出一次明确风险警告，然后执行原有 `open(final, 'wx')` 独占复制 |
| 原生 `EEXIST`、`EACCES`、`EXDEV`、`ENOSYS`、其他错误 | 原样传播，绝不当作“不支持”而回退 |
| 读写或 `fsync` 返回 `EINVAL` | 普通 I/O 失败，不进入原生提交的 `EINVAL` 回退门控 |
| 临时路径身份改变 | 拒绝提交或清理该替换目录项 |
| 提交之后关闭句柄失败 | 报告失败，但不删除已经完整发布的最终文件 |

`EINVAL` 并不在所有系统调用场景下唯一表示“不支持”。这里的门控限定为固定 flags、普通临时文件、不同源/目标目录项、同一父目录等前置条件成立之后的原生调用，并且按 owner 的明确约定处理。不能把所有 I/O 层的 `EINVAL` 都吞掉。

## 已跑证据及其边界

固定 Linux Node 和自有规范 linked 测试库上的作者结果如下，最终独立审查报告另行绑定精确补丁哈希：

| 验证 | 结果与范围 |
|---|---|
| 核心错误/身份/取消测试 | JITless 18/18；严格 O0 18/18，均零 skip |
| 正式独立 preload 接入原 provider | 附件、会话外层与既有锁测试 24/24，零 skip |
| Linux/Android 分支对照 | 6/6；真实 Linux 硬链接 inode、原 native flock 及非 OHOS `EACCES` 行为 |
| 启动矩阵 | 7/7：旧环境变量不启用、缺 binding、错误版本、重复安装、真实 linked 启动、Worker 继承 |
| SIGKILL | 两个实际 provider，各 6 个阶段，共 12 组；详情见下表 |
| Android 整树比较 | 30,444 个条目、26,871 个普通文件，与 afb5cdd 旧公共链逐块零差异；目录模式和符号链接目标也相同 |
| OHOS 补丁链 | 17 个已登记补丁重放与幂等性通过；OHOS 成品树回用于 Android 时明确拒绝且不改树 |

启动矩阵首轮有一个测试夹具错误：父进程的 `--input-type=module` 被 eval Worker 继承，而夹具错误使用 `require`。原始 6 过 1 败日志保留；改为 ESM 夹具后 7/7。没有借此修改产品实现或放宽预加载断言。

| 强杀阶段 | 强杀后 | 再次发布 |
|---|---|---|
| 原 helper 首块写完 | 最终文件残留 65,536 字节，源为 196,625 字节 | `EEXIST`，原缺陷保持可复现 |
| 新协议临时文件首块写完 | 最终文件不存在，已登记临时文件 65,536 字节 | 按 receipt 清理后成功发布完整内容 |
| 新协议临时文件同步返回 | 最终文件不存在，已登记临时文件完整 | 按 receipt 清理后成功发布完整内容 |
| 新协议原子改名已完成 | 最终文件完整，临时路径不存在 | `EEXIST`，完整最终文件与源均不变 |
| 注入原生 `EINVAL`，旧回退首块写完 | 最终文件再次残留 65,536 字节 | `EEXIST`，明确保留回退风险 |
| 创建临时文件后、取得/登记身份前 | 最终文件不存在，未知空临时文件保留 | 新尝试成功；旧未知临时文件仍保留，自动回收未解决 |

12 组脚本仅对真实 provider 源码追加临时导出，不改原辅助函数以便制造结论；新协议组通过同一个候选 JS 核心。已登记组的 receipt 由测试父进程预先创建并持久写入，不能据此声称 production provider 自己已经具有重启账本。`EINVAL` 负对照明确为注入，不能写成 Linux 所在文件系统实际拒绝了这个 flag。

Android 的规范整树摘要仍为 `ef9aa66792594a75bb87d4bd3ed3ddeff63d7f3dd5a11cac9d73955168fa1e36`。这些是固定 Linux 安装依赖树上的目标选择与真实逐字节比较，不是 Android arm64 构建、完整运行时归档、APK/HAP 或设备执行证明。

## 文件系统与耐久性待验

Linux `rename(2)` 文档说明 `RENAME_NOREPLACE` 需要底层文件系统支持；`fsync(2)` 文档明确文件同步不能单独保证目录项持久化，需要目录 fd 同步。来源：[rename(2)](https://man7.org/linux/man-pages/man2/rename.2.html)、[fsync(2)](https://man7.org/linux/man-pages/man2/fsync.2.html)。现有 provider 成功路径中保留了原来的目录同步，但本轮只强杀进程，没有模拟断电、存储故障或文件系统重挂载，不能宣称断电耐久性已经通过。

另一个具体限制来自 OpenHarmony 官方 `OpenHarmony-v6.1-Release` 的 [sharefs/inode.c](https://raw.gitcode.com/openharmony/kernel_linux_6.6/raw/OpenHarmony-v6.1-Release/fs/sharefs/inode.c)：该固定源码的 rename 路径在 `flags` 非零时返回 `-EINVAL`。取得文件的 SHA256 为 `7478c2b95cae359130dde7c283bba3d033c3855963300d463b9b01af3104b111`。这个源码结论不等于已确定真机应用目录挂载 sharefs，也不能由 Linux 成功外推所有 OpenHarmony 目录支持该 flag。

待真机核实：真实应用数据目录的文件系统及 `RENAME_NOREPLACE` 返回值；宿主 linked 模块注册/ABI；真实系统后台杀进程后读者与重试行为；目录同步的设备行为；生产持久登记及未知 orphan 处理策略。未经这些证据，不把整体 M3-1 标为完全恢复通过。

## 复跑入口

先按主交付说明应用 M4-7 目标补丁集合及本后置补丁，再用同包原生构建脚本产生 Linux linked 测试库或真实目标宿主。以下环境变量只是命令中的本地路径示意，不是产品门控：

```sh
LD_PRELOAD="$LINKED_LIBRARY" DSH_TEST_PREFIX="$PREFIX" DSH_GO_OHOS_SIM_PLATFORM=openharmony \
  "$NODE" --jitless --import "$SIM_PRELOAD" \
  --import ./runtime/ohos/publication/preload.mjs \
  --test --test-isolation=none \
  runtime/tests/ohos/publication-locks.test.mjs \
  runtime/tests/ohos/publication-integration.test.mjs

python3 -B runtime/tests/ohos/publication-startup.py \
  --node "$NODE" --simulation "$SIM_PRELOAD" \
  --linked-lib "$LINKED_LIBRARY" --out /绝对路径/startup.json

"$NODE" --jitless runtime/tests/ohos/publication-kill.mjs \
  --node "$NODE" --preload "$SIM_PRELOAD" --linked-lib "$LINKED_LIBRARY" \
  --before-prefix "$BEFORE_PREFIX" --candidate-prefix "$PREFIX" \
  --out /绝对路径/publication-kill.json
```

强杀脚本的父进程负责创建、登记并终止本测试的子进程，因此父进程本身不加载禁止 `child_process` 的 O0 预加载；每个被测子进程都加载严格 O0。脚本最终仅删除自己创建的测试目录及临时导出模块，不扫描应用目录中的未知发布文件。整体交付不附第三方源码或 tarball。
