/// 连接飞牛 fnconnect 后面的 DSH。
///
/// 与本地/隧道的差别只在认证方式：网关用飞牛会话 Cookie 鉴权，并（按
/// [FnConnectTarget.host]）把请求转给上游 DSH；DSH 客户端本身完全不变，
/// 仍然是 HTTP + WebSocket，二者都带 `/app/deepseek-harness/fngateway` 前缀。
library;

import 'package:dsh_client/dsh_client.dart';

import 'fnconnect.dart';

/// 用飞牛会话 Cookie 连上 [target] 上的 DSH。
///
/// [cookieHeader] 是 [readFnosCookies] 抓到的完整 `k=v; k2=v2` 串，
/// 由网关校验并注入 DSH 会话；[FnConnectTarget.host] 作为 `Host` 头，
/// 让 DSH 的 host fence 看到网关的公开域名。
///
/// 连接失败（网络、Cookie 失效、DSH 未启动）会抛 [DshRemoteException] /
/// [SocketException] 等，调用方应重新走登录页刷新 Cookie。
Future<DshClient> connectFnosDsh({
  required FnConnectTarget target,
  required String cookieHeader,
  bool backgroundLists = true,
}) {
  return DshClient.connect(
    baseUri: target.dshBaseUri,
    cookieHeader: cookieHeader,
    hostHeader: target.host,
    backgroundLists: backgroundLists,
  );
}
