# O4a：鸿蒙批量虚拟进程后端

**本项是 O4 的可复核子集，不代表 O4 全部完成。未在真机核实。** 固定基底 `afb5cdd`、DSH `0.2.1-rc.4`、Node `24.22.1`。**v3 完整替代 v1/v2，不叠加应用。** 当前支持批量 `bash` / `sh -c` 和部分 `rg` 模板；`node` 脚本、`git` 子命令、交互字节通道、实时 shell 输出尚未启用。它们必须保持不可用，不能在 O6 中报为可用。

## 接入与行为

Cordis 的 `subprocess` 提供者改为本目录的 `index.mjs`，`sandbox` 提供者改为 `sandbox.mjs`；**保留原 `@deepseek-ai/dsh-bash-sandbox`、`dsh-sandbox-policy`、`dsh-user-approval` 和 `tool-bash`**。后两者继续负责逐会话策略与单次审批。不要直接把 shell 换成没有 `sandboxMode` 的 `LocalBashExecutor`。DSH overlay 的 `name` 是匹配断言，不能用同 id 加新 name 来换实现：应禁用旧条目，再插入 `ohos-subprocess` / `ohos-sandbox` 新 id；服务注入名仍为 `subprocess` / `sandbox`。该差异已在主代理的真实 App 启动中定位并验证。

示例 subprocess 配置：

```json
{
  "workspaceRoots": ["/应用已授权的工作区"],
  "temporaryRoot": "/应用私有临时目录"
}
```

目录必须已存在，配置只来自宿主。没有传 `temporaryRoot` 时，服务用 `mkdtemp` 建立独立目录。所有根先经 `realpath` 规范化；拒绝把 `/` 授为根。不要把共享 `/tmp`、整个用户目录或其他应用目录配置为临时根。虚拟环境中的 `TMPDIR` 强制指向本服务的私有临时目录。服务的只读 `temporaryRoot` getter 供随后工作区快照适配器取宿主授权目录；不能用任意 env 扩大授权根。

`sandbox.confine()` 发放随机、单次的 argv 票据。策略留在宿主 Map 中，不放进可伪造的环境变量；prepare 与 spawn 解封后的实际 argv 共用无 NUL / 非空命令校验；票据不能把非法脚本藏在外壳后绕过原子进程限制。spawn 在进入队列前消费票据，重复使用、任意猜测和取消后的票据均被拒绝。`read-only` 拒绝所有受限 FS 写方法；`workspace-write` 将可见的工作区收窄到该调用的会话根。原工具层获准的 `danger-full-access` 也只能访问宿主启动时授权的根。

每个任务在独立 `worker_threads` 中运行已固定的 just-bash 解释器。同一服务使用两个 FIFO 队列：直接 `rg` 独占一个搜索槽，其余命令共享一个执行槽，总共最多两个 worker。写操作仍串行；长 bash 不再阻塞直接搜索。bash 内部调用 rg 仍在执行槽，因为同一脚本可能同时写文件。搜索可能观察到同时执行任务或外部编辑器正在修改的文件，不宣称快照一致性。没有改写 `child_process`、`fs`、`process.cwd`、Request/Response 或其他 Node 全局。`python:false`、`javascript:false`，命令注册表排除了 SQLite、Python、JS 执行及网络命令。`defenseInDepth:false` 防止 just-bash 全局改写宿主内建入口；因此这里依赖受限解释器、命令表与 FS 边界，不宣称是能运行不可信任意 JS 的安全容器。

`ReadWriteFs` 的路径和符号链接检查能拒绝已存在的越界链接；检查与后续宿主文件操作之间不是原子的，不能对抗另一个宿主调用同时替换路径的竞态。因此返回的 `sandbox.enforcement` 是 `partial`。这不是完整 OS 沙箱，真机验证也不能把这一结构边界消掉。

## 与原 DSH 契约的对应

| 项目 | 当前实现与边界 |
| --- | --- |
| spawn / handle | 同步返回 handle；启动前已取消、非法 graceMs 与空命令在分配 worker 前同步拒绝；`done`、`terminate`、`waitForExit`、stdout/stderr 收集保留原形状。未知可执行命令返回 127 和题面要求的中文信息。 |
| 环境 | 复用 `dsh-subprocess.scrubbedParentEnv()`；显式 env 在其后覆盖，`undefined` 删除变量。不把父进程其余 `DSH_*` 身份和凭据透传给 worker。 |
| 参数 | argv 原样传给解释器；`bash/sh -c` 的脚本只在该语法位置解析，普通位置参数不做第二次插值。仅接受固定虚拟别名，任意 `/另一个目录/bash` 不会按 basename 偷换成 bash。 |
| 取消 / 超时 | 原 bash 执行器决定 timeout / aborted 分类，后端终止 worker 并等待其实际退出；排队任务也可取消。已发生的文件写入不会回滚。 |
| 尾部 / spill | 直接复用纯 JS 的 `dsh-subprocess-local/output` 导出；独立偏移读取、尾部截断、spill 上限及超限后不提供不完整 spill 文件沿用原行为。 |
| 输出时机 | just-bash 公开 exec API 完成后才交付输出；因此运行中和取消前的逐步输出不等价。stdout/stderr 的 raw pipe 可在完成后读取，并实测延迟消费 600,000 字节中文 stdout 与 200,000 字节 stderr 完整。**不宣称实时输出。** |
| stdin / control | 仅 ignore 和一次性 `{data}` 输入；交互 pipe / control 明确抛 `ERR_OHOS_STREAM_UNAVAILABLE`。没有 PTY。 |
| 内存和文件规模 | 受限 FS 单文件读取及复制上限 64 MiB，解释器输出上限 64 MiB，worker JS old-generation 上限 256 MiB；这些不是总 RSS 上限，也不意味着同时读写多个大文件都在上述内存内。 |

## rg 范围与真实差分

`dsh-tool-fs-search` 原模板在解析命令、超时、输出上限、错误分类与 NDJSON 消费上保持原路。仅 OHOS/显式仿真下把 `resolveRgPath()` 改为 Promise 包装的 `/dsh-go/ohos/bin/rg`。原 `--no-config` 在 JS 后端表示不读取外部 rg 配置。

just-bash 3.6.0 不能直接视为原生 ripgrep：其默认 smart-case、`--` 分隔符、`--sort=modified`、UTF-8 JSON 偏移、无换行末行、glob 与忽略规则优先级均有差异。本适配器固定大小写默认值、保留字面路径、按 mtime 排序、通过锁内 RE2JS 的公开 UTF-8 matcher 生成匹配记录，保留字节坐标、真实换行和空行。整个入口把路径 I/O / 解析异常映射为 exit 2，不能让 DSH 将错误当作 exit 1 的零结果。JSON 仅交付 DSH 实际消费的 `match` 记录，不提供 ripgrep 的统计、summary 或上下文格式。

已测可用范围：默认目录文本搜索、中文与 Unicode 属性匹配、常规分组/选择、单个开头 `(?i)` / `(?-i)`、`^` / `$` / 空模式及可产生空匹配的选择与重复、明确路径、固定字符串、负向简单 glob；`--files --no-ignore --hidden --sort=modified` 配合简单正向 glob 与 DSH 的 VCS 排除项。相同 mtime 的文件采用路径稳定排序；不承诺与原生未定义的同时间顺序一致。

以下目前明确报错，返回 2，并提示连接电脑执行：grep 的正向 include glob；含 `**` 或花括号的正向 glob；RE2 与 Rust 默认 Unicode 语义不同的 `\w/\d/\s/\b` 及其反类；局部/组合内联标志；未列入解析器的其他参数；含换行符的显式搜索路径。默认显式二进制搜索也报错，可以明确传 `--text`。无效 UTF-8 的 JSON 文本搜索拒绝输出替换字符结果。这些是尚未完成的能力，不计入完整兼容。

DSH 随包的 `@vscode/ripgrep 1.18.0` 实际二进制为 ripgrep `15.0.0`（rev `3a612f88b8`）；与虚拟后端在同一真实目录上做 33 项差分：修复后 27 项比较相同，6 项因上述未实现范围而明确拒绝。六项分别为 Unicode word、默认显式二进制、四种正向 include glob。v1 的 21 项另以宿主 ripgrep `15.2.0` 复测，分类相同；v2/v3 新增的 12 项以 DSH 实际 15.0.0 为准。对照还确认：非空匹配紧邻的空匹配不重复报告，无 LF 末行的 EOF 空匹配保留 match 行但不列出该 submatch，不能只比较匹配行数。早期测量夹具误把原生 stdin 设为 pipe，导致无 path 的 rg 搜索空 stdin；第二版已改为与 DSH 相同的 `ignore` 并消除 mtime 并列，第一版不作实现缺陷证据。

默认遍历与全部 Rust regex / gitignore 边缘语义仍没有穷尽验证。真实 DSH `include` 参数的功能恢复是后续 O4 子项；不能用这份有限范围报告宣布 TASK O4 完成。

## 安装与复跑

manifest 中直接声明的运行时依赖保持题面已批准的固定版本：`just-bash 3.6.0`（Apache-2.0）、`isomorphic-git 1.44.9`（MIT）。后者已锁定供后续 O4 使用，本项不导入、不启用 git。v2 另直接使用它们现有依赖闭包中的 `re2js 1.3.3`（MIT，来自 just-bash）公开 API，原因是 just-bash 的 JSON 空匹配循环越界。它已在原 `package-lock.json` 锁定，未引入新 npm 包或改 manifest/锁文件；但直接 import 增加了对其公共 UTF-8 matcher API 和 npm 安装布局的耦合。安装与升级时必须保留该精确版本，若改为 manifest 直接依赖须先由本机决定。依赖完整性由 `package-lock.json` 固定。安装跳过 lifecycle scripts 和可选原生依赖；Python/SQLite 等传递依赖不会在当前命令注册表中加载。

从 `afb5cdd` 根目录应用独立补丁后，使用官方 Node 24.22.1：

```bash
git apply O4a-virtual-process-v3.patch
export PATH="/Node-24.22.1/bin:$PATH"
npm ci --prefix runtime/ohos/process --ignore-scripts --omit=optional
node runtime/ohos/process/link-dsh.mjs /已装DSH的独立prefix
```

DSH 厂商包补丁为 `runtime/patches/ohos-virtual-process.diff`，`pins.json` 只登记 `0.2.1-rc.4` 两个文件的 before/after SHA256。完整 OHOS 前缀用 `runtime/lib/rtbuild.py patch-dsh --prefix ... --dsh-version 0.2.1-rc.4 --target ohos`。阶段验证只要本 diff 时，把它拷到临时补丁目录，旁边放一份 schema 2 的 pins：`targetSets` 为 `{"android": [], "ohos": ["ohos-virtual-process.diff"]}`，`patches` 只含本项条目；再传 `--patches <临时目录> --target ohos`。不要对指向共享 npm-ci 包的符号链接树运行全部厂商补丁。

```bash
NODE=/Node-24.22.1/bin/node \
OHOS_TEST_PROCESS_PREFIX=/仅应用O4厂商补丁的独立prefix \
OHOS_TEST_BASE_PREFIX=/未修改DSH的prefix \
OHOS_SIM_PRELOAD=/已复核O0/runtime/ohos/sim/preload.mjs \
bash runtime/ohos/process/test.sh
```

`process.test.mjs` 24 项、`process-integration.test.mjs` 11 项、`process-policy.test.mjs` 8 项：普通 Node 与 O0 严格仿真各 43/43，0 skip、0 TODO。Android 条件对照 3/3：两个 OHOS 服务不能误挂载、rg 原 resolver 与 Promise 契约不变、实际注册的工具 description/schema 逐字相同。审批测试走真实 ToolRuntime、Session、SandboxPolicy、ApprovalService；用户答复是测试事件通道中的显式 allowed-once/rejected，未以绕过审批的 stub 替代执行路径。

O0 环境同时启用 `--jitless`、删除 WebAssembly、禁用所有 `child_process` 入口、限制 dlopen、link 模拟 EACCES。测试证明的是这个 Linux 宿主仿真范围，尚不证明 OpenHarmony 真机性能、SDK/宿主 worker 支持、文件系统竞态或后台冻结行为。

## v1/v2 失败与 v3 修复证据

v1 的独立审查 `cb25400e…` 为 BLOCKED：缺失路径和合法零宽正则都可落为 exit 1，真实 DSH 将其误读成 `noMatches:true`。原独立夹具的断言未改，冻结 v1 为 2 PASS / 2 FAIL，v2 候选为 4 PASS；另外两项只读写入口和延迟管道收尾原本就通过，不能说成四个实现缺陷。

主代理另外实际复现：直接 spawn 拒绝 NUL 命令，prepare 后却可执行。v2 已增加真实 tool-bash / sandbox.confine / 直接 spawn 三路径回归，非法命令在分配 worker 和票据前被拒绝。v2 独立复核还发现一个既有缺陷：显式给出 `.gitignore` 忽略的文件时，借用 just-bash `--files` 会过滤该文件，真实 DSH 相对与绝对路径均误报零结果。v3 只把显式文件从目录遍历中分开：已指定文件按受限 FS 读取，目录仍沿原规则；没有全局关闭 ignore。新增真实 DSH 的 ignored/hidden/负向 glob 回归，审查方默认遍历的负对照也必须保留。

冻结前并行负载曾令一个普通 shell 成功测试超过夹具原 2 秒预算。仅将普通成功用例共用的 fixture 默认预算改为 15 秒，显式 timeout 回归仍是 120 毫秒，生产代码的预算与分类未变；旧失败日志保留。正式结论以绑定本补丁 SHA256 的独立复核报告为准；这些结果不覆盖未实现的 include、node、git 或实时输出。

## 可核对的源材料

- 固定 npm-ci 包 `@deepseek-ai/dsh-subprocess`、`dsh-subprocess-local/lib/runner-launch-B2zsQ1Dz.js`：stdio、生命周期与收集契约；仅导入其公开的纯 JS output 子路径。
- 同版本 `dsh-tool-fs-search/lib/index.js`：`buildGrepCommand`、`buildGlobCommand`、`runRipgrep`、`parseGrepMatches`；真实集成测试直接调用这些函数。
- 同版本 `dsh-tool-bash`、`dsh-bash-sandbox`、`dsh-user-approval`：工具审批先于执行，策略来自会话，批准只对单次调用有效。
- [just-bash 官方项目](https://github.com/vercel-labs/just-bash) 与锁定 npm 包的 ReadWriteFs/MountableFs/CommandContext 声明及 rg bundle。
- [Node 24.22.1 worker_threads 文档](https://nodejs.org/download/release/v24.22.1/docs/api/worker_threads.html)。
- [isomorphic-git 官方文档](https://isomorphic-git.org/docs/en/quickstart)：后续 git 适配还需处理 DSH 工作区快照的独立 index/object 环境，不能把常用八个子命令当作完整 DSH 覆盖。

- [RE2JS 官方项目](https://github.com/le0pard/re2js) 及锁定包 1.3.3 的 matcher(number[]) / find / start / end 公开 API；字节坐标以原生差分为证据。
- [ripgrep 官方指南](https://github.com/BurntSushi/ripgrep/blob/master/GUIDE.md)；本文具体行为数据由随 DSH 分发的 15.0.0 实测，而非以最新版文档代替已锁版本。

## M3-3 进程内标记迁移

本附属差分只在已审 O4a v3（补丁 SHA256 `2f134c973c565b0b771acdff483537e85a844ee6d7faf5ad5cdea12d418c2581`）上迁移门控。生产服务、rg resolver 与 bash 说明只判断 `openharmony` 平台或显式预加载设置的 `Symbol.for('dsh.go.ohos.sim') === true`，不再读取旧 `DSH_GO_OHOS_SIM` 环境开关。

测试先应用 M3-3 主包，以取得 `sim/marker.mjs` 与新版完整预加载器。`test.sh` 的 Android 组故意携带旧环境变量，JIT 组只加载 marker，严格组加载完整 O0。Worker 不靠环境变量建立标记，而由默认继承的 `--import` 再次运行预加载；仅显式仿真下转发平台覆写配置。没有改动 argv 校验、权限票据、命令注册、rg 搜索语义或取消实现。

O4a 原有范围与限制不变；本迁移不把尚未完成的 node 脚本、实时输出或 O4b 硬取消宣布可用。
