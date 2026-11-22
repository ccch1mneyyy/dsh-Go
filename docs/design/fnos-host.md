# 飞牛 fnOS 主机（fnconnect 网关）

第三种远程主机：一台飞牛 NAS 上的 DSH，经飞牛的 **fnconnect** 外网访问域名
`https://<fnconnect-id>.fnos.net` 和 **统一网关** 暴露给外网。手机不需要与
NAS 在同一局域网，也不需要公网 IP 或端口映射。

## 连接链路

```
App ──HTTPS(Session Cookie)──▶ https://<id>.fnos.net/app/<app>/fngateway ──▶ NAS 上的 DSH
    └─WebSocket（同一 Cookie、同一挂载路径）─┘
```

- fnconnect 把请求送进飞牛统一网关；网关校验**飞牛登录态**，再把请求转给
  `deepseek.harness` 应用。所以客户端要同时带两样东西：
  1. 飞牛的会话 Cookie（`k=v; k2=v2`，由登录页的 WebView 写入 CookieManager）；
  2. 网关看到的公开 `Host`（`<id>.fnos.net`），DSH 的 host fence 按它放行。
- DSH 客户端本身不变：HTTP 与 WebSocket 都走 `baseUri` 的挂载前缀
  （默认 `/app/deepseek-harness/fngateway`）。

## 登录一次

`FnosLoginPage`（`lib/fnos/fnos_webview.dart`）用 WebView 打开
`https://<id>.fnos.net`，用户在那里登录飞牛账号。页面每秒读一次
`CookieManager`；拿到 Cookie 后调用 `probeFnosDsh`：

- 带 Cookie GET `dshBaseUri`，10 秒超时；
- 200 且响应体不含 `invalid token` → 网关已鉴权、DSH 可达；
- 401/403、404、其它状态、TLS/网络/超时分别给出原因（绝不打印 Cookie）。

成功后 Cookie 存入安全存储（`remote.fnos_session`），之后每次连接直接用；
超过 25 天提示重新登录（有效期满由服务端决定，客户端只保守提醒）。

## 网关路径可配置

不同 DSH 安装方式暴露的位置不同：「应用中心 / fpk 安装」走
`/app/deepseek-harness/fngateway`；自建反向代理 / Docker 可能是 `/dsh`、
`/deepseek` 等。`parseFnConnectInput(raw, gatewayPath:)` 接受 ID、`<id>.fnos.net`、
完整 URL 或自定义路径；设置页的「高级」和组织好的
`commonDshGatewayPaths` 预设让用户不必背路径。路径随主机保存。

## 与其它主机的关系

- ssh / relay / local 的代码与行为完全不变；`HostKind.fnos` 只新增一种。
- `HostRef.fnos(id)` 参与现有的主机切换、会话缓存分区
  （`read_list_identity` 用 fnconnect ID + 网关路径 + 会话时间戳区分）。
- 本版 fnOS 主机**不**提供 App 内「打开 DSH Web」与 Island 插件页
  （`dsh_web_launcher.dart` / `island_gate.dart` 明确返回不可用）；
  其余能力与远程主机一致。

## 测试

- `test/fnos/fnconnect_test.dart`：输入解析（ID/域名/URL/自定义网关路径/非法输入）；
- `test/fnos/fnos_auth_test.dart`：会话序列化、probe 状态判定、MethodChannel mock；
- 既有 `test/remote/**` golden 随该主机入口一起更新。
