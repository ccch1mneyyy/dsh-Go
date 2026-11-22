// 飞牛 fnOS 会话：存储格式/过期判断、网关探测判定，以及原生 Cookie 通道契约。
// 不连网、不开 WebView。

import 'package:dsh_app/fnos/fnconnect.dart';
import 'package:dsh_app/fnos/fnos_auth.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FnosSession', () {
    test('toJson/fromJson 往返', () {
      final savedAt = DateTime.fromMillisecondsSinceEpoch(1700000000000);
      final session = FnosSession(cookieHeader: 'fnos=a; token=b', savedAt: savedAt);
      final json = session.toJson();
      expect(json['cookieHeader'], 'fnos=a; token=b');
      expect(json['savedAt'], 1700000000000);

      final restored = FnosSession.fromJson(json);
      expect(restored.cookieHeader, session.cookieHeader);
      expect(restored.savedAt, savedAt);
    });

    test('fromJson 也接受 ISO-8601 的 savedAt', () {
      final restored = FnosSession.fromJson({'cookieHeader': 'fnos=a', 'savedAt': '2026-01-02T03:04:05.000Z'});
      expect(restored.savedAt, DateTime.utc(2026, 1, 2, 3, 4, 5));
    });

    test('fromJson 缺字段抛 FormatException', () {
      expect(() => FnosSession.fromJson(const {}), throwsFormatException);
      expect(() => FnosSession.fromJson(const {'cookieHeader': 'a=b'}), throwsFormatException);
      expect(() => FnosSession.fromJson(const {'cookieHeader': '', 'savedAt': 1700000000000}), throwsFormatException);
    });

    test('isStale：25 天内不算过期，之后算', () {
      expect(FnosSession.now('a=b').isStale, isFalse);
      expect(
        FnosSession(cookieHeader: 'a=b', savedAt: DateTime.now().subtract(const Duration(days: 24))).isStale,
        isFalse,
      );
      expect(
        FnosSession(cookieHeader: 'a=b', savedAt: DateTime.now().subtract(const Duration(days: 26))).isStale,
        isTrue,
      );
    });

    test('toString 不包含 Cookie 值', () {
      final session = FnosSession.now('fnos-secret-value=1');
      expect(session.toString(), isNot(contains('fnos-secret-value')));
    });
  });

  group('probe 判定', () {
    test('200 且无 invalid token → 已登录', () {
      final result = classifyFnosProbeResponse(statusCode: 200, body: '<!doctype html><title>DSH</title>');
      expect(result.authenticated, isTrue);
      expect(result.statusCode, 200);
      expect(result.detail, isNull);
    });

    test('200 但 body 含 invalid token → 未登录（大小写不敏感）', () {
      for (final body in ['Invalid Token', 'INVALID TOKEN', '{"error":"invalid token"}']) {
        final result = classifyFnosProbeResponse(statusCode: 200, body: body);
        expect(result.authenticated, isFalse, reason: body);
        expect(result.detail, contains('invalid token'));
      }
    });

    test('非 200 → 未登录，给状态码原因', () {
      final unauthorized = classifyFnosProbeResponse(statusCode: 401, body: '');
      expect(unauthorized.authenticated, isFalse);
      expect(unauthorized.statusCode, 401);
      expect(unauthorized.detail, contains('401'));

      final notFound = classifyFnosProbeResponse(statusCode: 404, body: '');
      expect(notFound.authenticated, isFalse);
      expect(notFound.detail, contains('404'));
    });

    test('空 Cookie 不去请求，直接判未登录', () async {
      final target = parseFnConnectInput('mynas')!;
      final result = await probeFnosDsh(target: target, cookieHeader: '   ');
      expect(result.authenticated, isFalse);
      expect(result.statusCode, isNull);
      expect(result.detail, isNotNull);
    });
  });

  group('MethodChannel dsh/fnos-cookies', () {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    Object? Function(MethodCall call)? reply;

    setUp(() {
      calls.clear();
      reply = null;
      messenger.setMockMethodCallHandler(fnosCookieChannel, (call) async {
        calls.add(call);
        return reply?.call(call);
      });
    });

    tearDown(() => messenger.setMockMethodCallHandler(fnosCookieChannel, null));

    test('readFnosCookies → getCookie({url})，返回前去掉首尾空白', () async {
      reply = (_) => '  fnos=abc; token=def  ';
      final cookie = await readFnosCookies('https://mynas.fnos.net');
      expect(cookie, 'fnos=abc; token=def');
      expect(calls.single.method, 'getCookie');
      expect(calls.single.arguments, {'url': 'https://mynas.fnos.net'});
    });

    test('没有 Cookie / 空串都算未登录', () async {
      reply = (_) => null;
      expect(await readFnosCookies('https://mynas.fnos.net'), isNull);
      reply = (_) => '';
      expect(await readFnosCookies('https://mynas.fnos.net'), isNull);
    });

    test('原生异常不抛出，按未登录处理', () async {
      reply = (_) => throw PlatformException(code: 'boom');
      expect(await readFnosCookies('https://mynas.fnos.net'), isNull);
    });

    test('空 url 不发通道调用', () async {
      expect(await readFnosCookies(''), isNull);
      expect(calls, isEmpty);
    });

    test('clearFnosCookies → clearCookies()', () async {
      await clearFnosCookies();
      expect(calls.single.method, 'clearCookies');
    });
  });
}
