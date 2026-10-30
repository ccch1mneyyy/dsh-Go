# DSH Go 鸿蒙远程客户端（首版预览）

本目录是使用 ArkTS / ArkUI 编写的原生鸿蒙远程客户端工程，连接电脑上已经启动的
`dsh web` 主机。模型、工作目录和任务实际运行在主机上，手机负责查看会话、发送文本和接收回复。

**当前状态：最终源码已完成原生重编译、调试包签名验证及 MatePad Pro 重装启动；
真机模拟通信和官方 DSH 的登录、握手、会话列表、新建与快照同步已通过。**
尚未向真实模型发送消息，也未验证真实模型回复或 HTTPS；不能据此宣称完整 DSH 功能已经验证。

## 首版范围

- 使用主机地址和启动令牌登录，经 HTTP(S) RPC 与 WebSocket 接收主机数据。
- 刷新普通主会话列表，查看标题、主机目录和运行状态；列表过滤子代理会话。
- 新建会话，可填写**主机上的目录路径**，留空交由主机决定默认目录。
- 打开会话，读取快照，并接收持久化事件与助理文本增量。
- 以 `queue` 模式发送文本；是否排队和何时执行由主机处理。
- 显式请求停止当前会话的任务，并等待主机返回后续状态。

界面包含连接、会话列表和聊天三页。消息以主机返回的数据为准，不提前插入一条假定已送达的用户消息。
聊天仅显示明确来自用户的文本与助理文本，不展示上下文注入、推理内容或工具参数；目前按普通文本显示，
支持本机复制，没有 Markdown 或工具结果专用渲染。

首版不包含 Android 版的本机 Linux / DSH 运行环境，也不支持加密中继、附件、子代理路由、
审批或提问答复、历史分页、凭据持久化及自动重连。审批和提问需要回到原 DSH 主机界面处理，
本客户端不会自动授权。文本请求的时区当前固定为 `Asia/Shanghai`。

## 连接主机

1. 在电脑上启动并配置好 `dsh web`，取得当前主机进程给出的启动令牌。
2. 确认手机可以访问该主机的 HTTP(S) 地址。电脑终端里的 `127.0.0.1` 通常指电脑自身，
   不能直接作为另一台设备的地址；已有 USB 转发时，应使用对应转发地址。
3. 在“主机地址”中填写基址，例如 `http://192.168.1.10:3080`，在“启动令牌”中单独填写 token。
   不要把 `/?token=...` 的整条登录链接填进主机地址。地址输入不接受内嵌账号、查询参数或 URL 片段。
4. 点击“连接主机”。客户端完成令牌登录和主机 ready 握手后读取会话列表，再打开或新建会话。

启动令牌是 DSH 登录凭据，不是模型供应商 API key。主机地址决定连接目标及后续 RPC / WebSocket 地址，
token 只用于登录交换。客户端读取登录响应中的 `dsh-auth-*` Cookie，后续请求以该 Cookie 认证。
上游 Cookie 与登录时使用的主机及端口绑定；换主机或换地址应重新登录，不能复用另一地址的 Cookie。
主机信任检查或认证失败时，应检查地址和当前令牌，不应把“网络可达”当作“已登录”。

客户端源码仅在内存中处理 token 和 Cookie，不写凭据文件、登录日志或第三方遥测。
登录成功后清空令牌输入框；断开时清除客户端 Cookie。重新连接需要再次输入令牌。
这里描述的是客户端自身的存储行为，不代表已经完成系统、主机或反向代理的日志审计。

## 断开与停止任务的区别

“返回”、切换会话、断开连接、页面退出和网络断线，都不会发送 `session/cancel`。
切换会话时发送的 mux `cancel` 帧只结束旧订阅，**不会停止主机上的模型任务**。
只有聊天页的“停止任务”按钮调用明确的 `cancelSession` 入口，才请求主机停止任务。
收到停止请求的响应也不等同于任务已停止，最终状态仍以主机事件为准。

因此，手机断开后主机任务可能继续运行。发生发送错误时，也可能出现“主机已经收到消息，
手机没有收到确认”的情况。写入请求不会自动重试；应先重新连接、打开会话核对记录，再决定是否重发。

## 工程与协议实现

| 位置 | 用途 |
|---|---|
| `entry/src/main/ets/pages/Index.ets` | 三页界面及连接、会话、输入状态 |
| `entry/src/main/ets/network/protocol.ts` | RPC / mux 信封、参数和聊天文本投影 |
| `entry/src/main/ets/network/ClientCore.ts` | 登录、ready 握手、会话操作和断线处理 |
| `entry/src/main/ets/network/HarmonyTransport.ets` | 鸿蒙 RCP HTTP 与 NetworkKit WebSocket 适配 |
| `entry/src/main/ets/network/DshClient.ets` | 原生客户端入口 |
| `tests/network/` | Node 协议回归及验证边界说明 |

协议对照仓库的 `packages/dsh_client`，不是另行假定一套聊天服务接口：

- 登录：GET `/?token=...`，读取原始 302 / 303 与 `Set-Cookie`；HTTP 适配禁用自动跳转。
- RPC：POST `/api/session/list`、`create`、`prompt`、`cancel`，使用 `client-request` /
  `server-response` 信封；HTTP 200 中仍可能包含业务错误。
- 流：连接 `/api/remote.mux`，先打开 `$events` 并等待 ready，再打开 `session/follow`。
- 历史事件序号与助理流修订号分别去重；发现缺口时断开并提示重新打开，不继续显示缺失的流。

每次打开会话请求 `maxMessages=500`、`turnWindow={minMessages:50,minTurns:2}`，
没有“加载更早历史”的入口；这不是完整聊天历史导出。重新连接后通过新快照恢复显示。

原生 WebSocket 适配等待 `open` 事件后才发送首帧；`connect` 的返回值仅表示连接请求已受理。
连接时启用 API 26 的 `supportOriginPort`，保留默认 Origin 中的端口，避免主机同源检查因端口丢失拒绝握手。
因此当前工程最低和目标 SDK 均为 `26.0.0`，不再声明此前的 API 12 最低兼容范围。

## 运行协议测试

需要 Node.js 24 或更新版本，无需连接 DSH 主机或配置模型 API key。在仓库根目录运行：

```sh
node --test harmony/tests/network/protocol.test.mjs
```

也可以在本目录运行：

```sh
node --test tests/network/protocol.test.mjs
```

测试直接加载实际 `protocol.ts` 和 `ClientCore.ts`，使用仓库原有 Dart 客户端 fixture 与本地模拟传输，
覆盖登录令牌编码、Cookie 提取、RPC 业务错误及请求标识、真实回复记录、文本流投影和显式取消入口。
临时文件创建在 `tests/network/.test-*` 下，测试结束后清理。

2026-10-30 最终 Node 回归为 **6 项通过，0 项失败，0 项跳过**，包括新增的连接阶段断线竞态测试。
测试验证范围限于相应源码、fixture 和模拟传输，不能单独证明华为 Kit 或原生设备行为。
详细范围见 [通信层测试说明](tests/network/README.md)；真机结果另列如下。

## 原生构建与设备验证

使用 DevEco Studio 打开本 `harmony/` 目录，以 `entry` 为入口模块进行工程同步和构建。
当前配置声明 `runtimeOS=HarmonyOS`，最低和目标 SDK 均为 `26.0.0`，
包名为 `io.github.xunguangzlj.dshgo.native`，设备类型为 phone / tablet。
目前实测设备为 MatePad Pro，不能据此扩大为所有手机和平板均已通过。

常规验证流程：

1. 准备可用的官方 HarmonyOS SDK、Hvigor 和 OHPM 工具链，完成 DevEco 工程同步及依赖解析。
2. 执行原生编译，核对 ArkTS、ArkUI、RemoteCommunicationKit 与 NetworkKit 的实际编译诊断。
3. 在本地配置应用签名与设备，构建并安装 HAP；仓库中的签名配置目前为空，不包含证书和私钥。
4. 在设备上验证登录、会话列表、新建会话、发送文本、流式回复、停止任务及断线重新登录。
   重点核对离开页面或断网不会误停主机任务，以及输入错误令牌时的表现。

2026-10-30 使用官方 Windows Command Line Tools 26.0.0.851、HarmonyOS SDK 26.0.0.105
及 Hvigor 6.26.8 执行 `hvigorw --mode module -p product=default -p module=entry@default assembleHap --no-daemon`，
最终源码（包含连接阶段断线竞态修复）结果为 `BUILD SUCCESSFUL in 6 s 975 ms`，
产出 `entry/build/default/outputs/default/entry-default-unsigned.hap`。
随后完成调试包签名与签名验证，并在 MatePad Pro 重新安装、启动原生应用。
仓库不包含个人调试签名材料；本机构建成功不等于已经具备上游发布签名或应用市场上架资格。

工程声明了 `ohos.permission.INTERNET`。使用 USB 转发连接本机 DSH 协议模拟服务，已验证：

- 令牌登录、Cookie 传递、WebSocket ready、会话列表、新建会话与 follow 订阅。
- 真机发送测试文本，收到流式回复并最终显示 `OK`；回复来自模拟服务，不是真实模型生成。
- 慢速回复中显式点击停止后，模拟服务报告 `cancels=1`、`running=false`。
- 再次发送后返回列表并断开，连接数降为 `0`，模拟任务仍为 `running=true`，`cancels` 保持 `1`。
  这证明该实测路径没有把返回或断开误当成停止任务。

最新 Core 的真机真实主机验证使用官方 DSH `0.2.1-rc.2`，运行在不含模型凭据的隔离环境：
已通过原始登录 HTTP 303、ready 握手、会话列表、新建会话及 follow 快照同步。
未发送真实模型 prompt，也未验证真实模型的流式回复或停止；前述 `OK` 与取消计数仍属于模拟服务验证。

**尚未验证：真实模型消息与回复链路、HTTPS、其他设备及系统版本，以及首版范围之外的功能。**
上述真机结果限于本次设备、模拟服务场景和已列明的官方 DSH 接入路径，
不替代完整协议兼容性或所有生命周期场景测试。
与 [Issue #24](https://github.com/ccch1mneyyy/dsh-Go/issues/24) 的卓易通本地引擎问题相关，
本实现提供不依赖该引擎的原生远程入口；没有修复或验证 PRoot / 本地 DSH 引擎启动。

## 许可

本目录新增与移植源码沿用仓库根目录的 AGPL-3.0 许可。协议移植依据为
[DSH Go 源提交 e0ed2b9064ce5f15c03ae21625046ce97511e81e](https://github.com/ccch1mneyyy/dsh-Go/tree/e0ed2b9064ce5f15c03ae21625046ce97511e81e)
的 `packages/dsh_client`：`lib/src/` 下的 `connection.dart`、`carrier.dart`、`rpc_envelope.dart`、
`session_api.dart`、`agents_api.dart`、`mux.dart`、`models.dart`，以及该包的测试 fixture。
此处将其登录、RPC、mux 和文本投影逻辑改写为 TypeScript / ArkTS，并新增鸿蒙网络适配和 UI；
原项目署名与许可仍适用，详见仓库根 `LICENSE`。当前未引入第三方应用运行库。
当前工作树已快进至上游 DSH Go 1.0.2 的 `d38a39a`；上述协议移植来源提交保持不变。
