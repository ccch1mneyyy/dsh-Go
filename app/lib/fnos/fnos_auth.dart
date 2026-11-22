/// 飞牛 fnOS 会话：登录一次拿到的 Cookie 串、它的本地存储格式，以及
/// "这个 Cookie 在飞牛统一网关上还能不能连到 DSH" 的探测。
///
/// Cookie 是凭据，任何情况下都不打印、不写日志（[FnosSession.toString]
/// 也不含它的值）。用户可见的诊断文字走 l10n（[appL10n]），这里不硬编码文案。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../l10n/l10n.dart';
import 'fnconnect.dart';

/// 与原生 CookieManager 说话的通道（Android: `FnosCookiePlugin.kt`）。
const fnosCookieChannel = MethodChannel('dsh/fnos-cookies');

/// 读一次 WebView 在 [url] 下保存的 Cookie。
///
/// 返回完整的 `k=v; k2=v2` 头；没有 Cookie（或原生侧不可用）时返回 null。
Future<String?> readFnosCookies(String url) async {
  if (url.isEmpty) return null;
  try {
    final cookie = await fnosCookieChannel.invokeMethod<String>('getCookie', {'url': url});
    final trimmed = cookie?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  } on MissingPluginException {
    // 非 Android 宿主（或未注册插件）：当作没有登录态。
    return null;
  } on PlatformException {
    return null;
  }
}

/// 清掉 WebView 的全部 Cookie（退出账号 / 换一个 fnconnect ID 时用）。
Future<void> clearFnosCookies() async {
  try {
    await fnosCookieChannel.invokeMethod<void>('clearCookies');
  } on MissingPluginException {
    // 非 Android 宿主：没有可清的。
  } on PlatformException {
    // 清理失败不影响调用方继续（下一次登录会重新写 Cookie）。
  }
}

/// 一次飞牛登录会话的持久化形态。
///
/// 飞牛会话 Cookie 的有效期由服务端决定，客户端只保守地 25 天后重登。
class FnosSession {
  const FnosSession({required this.cookieHeader, required this.savedAt});

  /// 以当前时间记录一个新会话。
  factory FnosSession.now(String cookieHeader, {DateTime? at}) =>
      FnosSession(cookieHeader: cookieHeader, savedAt: at ?? DateTime.now());

  /// 从 [toJson] 的形状还原；缺字段或格式不对时抛 [FormatException]。
  ///
  /// `savedAt` 接受毫秒时间戳（本类的写法）或 ISO-8601 字符串（旧数据容错）。
  factory FnosSession.fromJson(Map<String, Object?> json) {
    final cookieHeader = json['cookieHeader'];
    if (cookieHeader is! String || cookieHeader.isEmpty) {
      throw const FormatException('FnosSession: cookieHeader missing');
    }
    final savedAt = switch (json['savedAt']) {
      final int milliseconds => DateTime.fromMillisecondsSinceEpoch(milliseconds),
      final String text => DateTime.tryParse(text),
      _ => null,
    };
    if (savedAt == null) throw const FormatException('FnosSession: savedAt missing or unparsable');
    return FnosSession(cookieHeader: cookieHeader, savedAt: savedAt);
  }

  /// 完整 Cookie 头：`k=v; k2=v2`。
  final String cookieHeader;

  /// 抓到这个 Cookie 的时间。
  final DateTime savedAt;

  /// 保守的过期时间：超过它就重新登录，不等服务端 401。
  static const staleAfter = Duration(days: 25);

  /// 是否该重新登录（超过 [staleAfter]）。
  bool get isStale => DateTime.now().difference(savedAt) > staleAfter;

  Map<String, Object?> toJson() => {'cookieHeader': cookieHeader, 'savedAt': savedAt.millisecondsSinceEpoch};

  @override
  String toString() => 'FnosSession(savedAt: ${savedAt.toIso8601String()}, stale: $isStale)';
}

/// 一次网关探测的结论。
class FnosProbeResult {
  const FnosProbeResult({required this.statusCode, required this.authenticated, this.detail});

  factory FnosProbeResult.fromJson(Map<String, Object?> json) => FnosProbeResult(
    statusCode: json['statusCode'] is int ? json['statusCode'] as int : null,
    authenticated: json['authenticated'] == true,
    detail: json['detail'] is String ? json['detail'] as String : null,
  );

  /// 网关 HTTP 状态码；连不上时为 null。
  final int? statusCode;

  /// Cookie 是否已被网关接受、DSH 页面可访问。
  final bool authenticated;

  /// 给界面看的简短原因（本地化，不含 Cookie 值）。
  final String? detail;

  Map<String, Object?> toJson() => {'statusCode': statusCode, 'authenticated': authenticated, 'detail': detail};

  @override
  String toString() => 'FnosProbeResult(status: $statusCode, authenticated: $authenticated, detail: $detail)';
}

/// 探测超时：连接、请求、读 body 合计不超过这个时间。
const fnosProbeTimeout = Duration(seconds: 10);

/// 用 [cookieHeader] 请求一次 [target] 的 DSH 入口，判断飞牛会话是否可用。
///
/// 判定见 [classifyFnosProbeResponse]：`200` 且 body 不含 `invalid token`
/// 即已登录。网络失败、超时、非 200、`invalid token` 都算未登录，
/// [FnosProbeResult.detail] 给出简短原因，绝不回显 Cookie。
Future<FnosProbeResult> probeFnosDsh({required FnConnectTarget target, required String cookieHeader}) async {
  final cookie = cookieHeader.trim();
  if (cookie.isEmpty) {
    return FnosProbeResult(statusCode: null, authenticated: false, detail: appL10n.fnosProbeNoCredentials);
  }
  final client = HttpClient()..connectionTimeout = fnosProbeTimeout;
  try {
    return await _probeOnce(client, target, cookie).timeout(
      fnosProbeTimeout,
      onTimeout: () => FnosProbeResult(statusCode: null, authenticated: false, detail: appL10n.fnosProbeTimeout),
    );
  } catch (error) {
    return _probeFailure(error);
  } finally {
    client.close(force: true);
  }
}

Future<FnosProbeResult> _probeOnce(HttpClient client, FnConnectTarget target, String cookie) async {
  final request = await client.getUrl(target.dshBaseUri);
  request.headers.set(HttpHeaders.cookieHeader, cookie);
  request.headers.set(HttpHeaders.acceptHeader, 'text/html,application/xhtml+xml;q=0.9,*/*;q=0.8');
  // 网关对已登录用户直接代理 DSH 页面；未登录时会跳到登录页，最终状态码仍是
  // 200，所以判定还要看 body 里的 invalid token（见 classifyFnosProbeResponse）。
  final response = await request.close();
  final body = await response.transform(const Utf8Decoder(allowMalformed: true)).join();
  return classifyFnosProbeResponse(statusCode: response.statusCode, body: body);
}

/// [probeFnosDsh] 的纯判定逻辑（单独导出，便于测试和诊断）。
FnosProbeResult classifyFnosProbeResponse({required int statusCode, required String body}) {
  final invalidToken = body.toLowerCase().contains('invalid token');
  if (statusCode == 200 && !invalidToken) {
    return const FnosProbeResult(statusCode: 200, authenticated: true);
  }
  if (invalidToken) {
    return FnosProbeResult(statusCode: statusCode, authenticated: false, detail: appL10n.fnosProbeInvalidToken);
  }
  return FnosProbeResult(
    statusCode: statusCode,
    authenticated: false,
    detail: switch (statusCode) {
      401 || 403 => appL10n.fnosProbeUnauthorized(statusCode),
      404 => appL10n.fnosProbeNotFound,
      _ => appL10n.fnosProbeHttp(statusCode),
    },
  );
}

FnosProbeResult _probeFailure(Object error) {
  final detail = switch (error) {
    TimeoutException() => appL10n.fnosProbeTimeout,
    HandshakeException() => appL10n.fnosProbeTlsFailed,
    SocketException() => appL10n.fnosProbeUnreachable,
    HttpException() => appL10n.fnosProbeBadResponse,
    _ => appL10n.fnosProbeFailed,
  };
  return FnosProbeResult(statusCode: null, authenticated: false, detail: detail);
}
