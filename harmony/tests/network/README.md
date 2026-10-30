# 通信层首版验证

在仓库根目录使用 Node 24 或更新版本运行：

```text
node --test harmony/tests/network/protocol.test.mjs
```

纯 TypeScript 协议和状态层与鸿蒙平台适配器分开。测试把真实源码复制到本目录临时子目录，改写扩展名以便 Node 原生加载 TypeScript，结束后删除；不替换协议实现，不访问DSH主机或模型供应商。

2026-10-30 最终执行上述命令，**6 项通过、0 失败、0 跳过**。新增回归覆盖 `Transport.open` 期间
两种 `onLost` 竞态，确保真实断线原因不被后续“连接已取消”覆盖；原实现为 5 通过、1 失败，最小修复后全部通过。
此修复后的最终源码另已完成原生重编译、签名验证、重装启动与下述真实主机接入；
这些是独立验收结果，不归入 Node 测试。

## 上游依据

源提交：[e0ed2b9064ce5f15c03ae21625046ce97511e81e](https://github.com/ccch1mneyyy/dsh-Go/tree/e0ed2b9064ce5f15c03ae21625046ce97511e81e)。
以下路径均位于该提交的 `packages/dsh_client`；本目录将其协议和状态逻辑改写为 TypeScript / ArkTS，
保留原项目来源说明并沿用根目录 AGPL-3.0 许可。

- `packages/dsh_client/lib/src/connection.dart`：GET `/?token=`，读取302/303的 `dsh-auth-*` Cookie；Cookie仅在同一个连接实例/主机地址使用。
- `carrier.dart` / `rpc_envelope.dart`：POST `/api/<endpoint>`，client-request / server-response信封，业务错误仍可能是HTTP200。
- `session_api.dart` / `agents_api.dart`：list、create、prompt、cancel、follow；follow使用 `request.address={kind:session,sessionId}`。
- `mux.dart`：`/api/remote.mux`，先打开 `$events` 等ready，再订阅follow；只接受item/end/error帧。
- `models.dart` 与 `test/fixtures/follow_reply_ok.jsonl`：快照/持久化事件/assistant-stream、修订号、文本压缩块。

以上移植与新增源码沿用仓库根AGPL-3.0许可；未引入第三方运行库。

## 接口

`network/DshClient.ets` 导出无参 `DshClient`，其方法为 connect、listSessions、createSession、watchSession、sendPrompt、cancelSession、disconnect、close，另外有 `onDisconnect` 回调。类型在 `network/protocol.ts`。

watchSession回调返回完整 `FollowUpdate.messages`，UI应直接替换；不要另行乐观插入用户消息。仅展示明确 `source.kind=user` 的用户文本及助理文本；运行时注入、推理、工具参数不会作为对话展示。持久化seq与assistant revision分别去重；出现缺口会关闭连接并报告，不会继续展示不完整流。

Cookie与启动令牌仅驻留内存；无日志、磁盘凭据缓存或第三方遥测。关闭页面、切换订阅、网络断开都不调用session/cancel；只有显式cancelSession入口会停止远程任务。逻辑流cancel帧仅取消旧订阅。

## 平台适配与验证边界

HTTP采用 `@kit.RemoteCommunicationKit` 的RCP Session，`requestConfiguration.transfer.autoRedirect=false`，读取原始Set-Cookie。RCP参考文档声明autoRedirect从API11可用；普通NetworkKit http的maxRedirects从API23才可用，因此首版不用它。

WebSocket 采用 `@kit.NetworkKit`，等待 `open` 事件后才发送首帧，而不是把 `connect` 返回成功当成握手完成。
启用 API 26 的 `supportOriginPort`，防止默认 Origin 丢失端口后被主机拒绝；当前最低与目标 SDK 均为 `26.0.0`。

2026-10-30 已使用官方 Windows CLT 26.0.0.851、SDK 26.0.0.105、Hvigor 6.26.8 完成原生构建，
最终源码重编译为 `BUILD SUCCESSFUL in 6 s 975 ms`，调试 HAP 签名验证后在 MatePad Pro 重装启动。
通过 USB 本机模拟服务完成了登录、ready、列表、新建、
follow、文本发送与流式最终 `OK`；慢速模拟任务显式停止后 `cancels=1/running=false`，
再次发送后返回并断开时连接数为 0、`running=true`、`cancels` 仍为 1。

上述 `OK` 和停止/断开计数是独立的原生设备模拟链路证据，不能归入 Node 测试或真实模型结果。
另使用无模型凭据的隔离官方 DSH `0.2.1-rc.2`，最新 Core 真机通过原始登录 303、ready、
会话列表、新建及 follow 快照同步。未发送真实模型 prompt，未验证真实模型回复或 HTTPS，
不能将这些接入结果扩大为全部功能兼容。

首版只支持可直接访问的DSH web主机、普通主会话、文本消息及有限历史窗口。不支持dsh_remote加密中继、附件、工具结果渲染、审批/提问答复、子代理路由、历史分页、持久化Cookie及自动重连。审批请在原DSH主机界面处理；本客户端不会自动批准。手动重新连接将获取新快照。写入请求不会自动重试，网络错误时应先重新连接核对是否已送达。
