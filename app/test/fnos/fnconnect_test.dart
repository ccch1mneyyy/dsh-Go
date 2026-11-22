// 飞牛 fnconnect 输入解析与网关路径：纯 Dart 逻辑，不连网、不开 WebView。

import 'package:dsh_app/fnos/fnconnect.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('网关路径可自定义', () {
    test('normalizeDshGatewayPath：空 → 默认，补前导斜杠、去尾斜杠', () {
      expect(normalizeDshGatewayPath(null), defaultDshGatewayPath);
      expect(normalizeDshGatewayPath(''), defaultDshGatewayPath);
      expect(normalizeDshGatewayPath('  '), defaultDshGatewayPath);
      expect(normalizeDshGatewayPath('dsh'), '/dsh');
      expect(normalizeDshGatewayPath('/dsh/'), '/dsh');
      expect(normalizeDshGatewayPath('/app/deepseek-harness'), '/app/deepseek-harness');
    });

    test('normalizeDshGatewayPath：非法字符拒绝', () {
      expect(normalizeDshGatewayPath('/bad path'), isNull);
      expect(normalizeDshGatewayPath('/dsh<'), isNull);
      expect(normalizeDshGatewayPath('/a"b'), isNull);
    });

    test('只用 ID + 自定义路径', () {
      final target = parseFnConnectInput('mynas', gatewayPath: '/dsh');
      expect(target, isNotNull);
      expect(target!.dshBaseUri, Uri.parse('https://mynas.fnos.net/dsh'));
      expect(target.gatewayPath, '/dsh');
      expect(target.fnconnectId, 'mynas');
    });

    test('输入自带路径时，以输入里的为准', () {
      final target = parseFnConnectInput('https://mynas.fnos.net/custom/gw', gatewayPath: '/dsh');
      expect(target!.gatewayPath, '/custom/gw');
    });

    test('非法自定义路径整体拒绝', () {
      expect(parseFnConnectInput('mynas', gatewayPath: '/bad path'), isNull);
    });

    test('withGatewayPath：同 ID 换路径，非法返回 null', () {
      final base = parseFnConnectInput('mynas')!;
      final changed = base.withGatewayPath('/app/deepseek-harness');
      expect(changed!.fnconnectId, 'mynas');
      expect(changed.gatewayPath, '/app/deepseek-harness');
      expect(base.gatewayPath, defaultDshGatewayPath);
      expect(base.withGatewayPath('/bad path'), isNull);
    });

    test('常见路径示例包含默认路径', () {
      expect(commonDshGatewayPaths.first, defaultDshGatewayPath);
      for (final path in commonDshGatewayPaths) {
        expect(normalizeDshGatewayPath(path), path);
      }
    });
  });

  group('parseFnConnectInput', () {
    test('裸 ID → <id>.fnos.net + 默认网关路径', () {
      final target = parseFnConnectInput('mynas');
      expect(target, isNotNull);
      expect(target!.fnconnectId, 'mynas');
      expect(target.host, 'mynas.fnos.net');
      expect(target.origin, Uri.parse('https://mynas.fnos.net'));
      expect(target.loginUri, target.origin);
      expect(target.dshBaseUri, Uri.parse('https://mynas.fnos.net/app/deepseek-harness/fngateway'));
      expect(target.dshBaseUri.path, defaultDshGatewayPath);
      expect(defaultDshGatewayPath, '/app/deepseek-harness/fngateway');
    });

    test('只写域名', () {
      final target = parseFnConnectInput('mynas.fnos.net');
      expect(target, isNotNull);
      expect(target!.fnconnectId, 'mynas');
      expect(target.dshBaseUri.toString(), 'https://mynas.fnos.net$defaultDshGatewayPath');
    });

    test('带 https:// 的源', () {
      final target = parseFnConnectInput('https://mynas.fnos.net');
      expect(target, isNotNull);
      expect(target!.origin, Uri.parse('https://mynas.fnos.net'));
      expect(target.dshBaseUri.path, defaultDshGatewayPath);
    });

    test('大小写归一', () {
      expect(parseFnConnectInput('MyNas')!.fnconnectId, 'mynas');
      expect(parseFnConnectInput('https://MyNas.fnos.net')!.host, 'mynas.fnos.net');
    });

    test('完整 URL 带默认路径：原样使用', () {
      final target = parseFnConnectInput('https://mynas.fnos.net/app/deepseek-harness/fngateway');
      expect(target, isNotNull);
      expect(target!.dshBaseUri, Uri.parse('https://mynas.fnos.net/app/deepseek-harness/fngateway'));
    });

    test('完整 URL 带其它路径：用其 origin + 该路径', () {
      final target = parseFnConnectInput('https://mynas.fnos.net/app/dsh');
      expect(target, isNotNull);
      expect(target!.origin, Uri.parse('https://mynas.fnos.net'));
      expect(target.dshBaseUri, Uri.parse('https://mynas.fnos.net/app/dsh'));
    });

    test('不带 scheme 的 域名+路径', () {
      final target = parseFnConnectInput('mynas.fnos.net/app/deepseek-harness/fngateway');
      expect(target, isNotNull);
      expect(target!.dshBaseUri, Uri.parse('https://mynas.fnos.net/app/deepseek-harness/fngateway'));
    });

    test('末尾斜杠归一，query/fragment 忽略', () {
      final target = parseFnConnectInput('https://mynas.fnos.net/app/deepseek-harness/fngateway/?x=1#frag');
      expect(target, isNotNull);
      expect(target!.dshBaseUri.toString(), 'https://mynas.fnos.net/app/deepseek-harness/fngateway');
      expect(target.dshBaseUri.hasQuery, isFalse);
      expect(target.dshBaseUri.hasFragment, isFalse);
    });

    test('显式 443 端口等同默认端口', () {
      final target = parseFnConnectInput('https://mynas.fnos.net:443/');
      expect(target, isNotNull);
      expect(target!.host, 'mynas.fnos.net');
      expect(target.origin.toString(), 'https://mynas.fnos.net');
    });

    test('非 443 端口保留在 host 与源里', () {
      final target = parseFnConnectInput('https://mynas.fnos.net:8443/app/dsh');
      expect(target, isNotNull);
      expect(target!.host, 'mynas.fnos.net:8443');
      expect(target.origin, Uri.parse('https://mynas.fnos.net:8443'));
      expect(target.dshBaseUri, Uri.parse('https://mynas.fnos.net:8443/app/dsh'));
    });

    test('非法输入返回 null', () {
      for (final raw in [
        '',
        ' ',
        ' mynas',
        'mynas ',
        'my nas',
        'mynas\n',
        'mynas!',
        'MyNas!',
        '-mynas',
        'mynas-',
        'mynas..fnos.net',
        'https://',
        'https://.fnos.net',
        'https://mynas.fnos.net.evil.com',
        'https://evil.com/?next=mynas.fnos.net',
        'http://mynas.fnos.net',
        'ftp://mynas.fnos.net',
        'mynas.fnos.net@evil.com',
        'https://user:pass@mynas.fnos.net',
        'https://mynas.fnos.net/<script>',
        'https://mynas.fnos.net/path with space',
      ]) {
        expect(parseFnConnectInput(raw), isNull, reason: '应拒绝：$raw');
      }
    });
  });
}
