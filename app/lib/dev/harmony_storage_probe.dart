// 鸿蒙真机存储验证入口；正式应用仍从 main.dart 启动。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:url_launcher/url_launcher.dart';

const _store = _ProbeStore();
const _originalStore = FlutterSecureStorage();
const _key = 'dsh.harmony.probe.persist.v1';
const _temporaryKey = 'dsh.harmony.probe.temporary.v1';
const _value = '仅用于本机存储验证 🐳';

// 独立命名空间允许验证清空操作，不接触正式凭据。
class _ProbeStore {
  const _ProbeStore();
  static const _channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  Future<T?> _call<T>(String method, [Map<String, Object?> args = const {}]) => _channel.invokeMethod<T>(method, {
    ...args,
    'options': {'dshNamespace': 'probe_v1'},
  });
  Future<void> write({required String key, required String? value}) =>
      value == null ? delete(key: key) : _call<void>('write', {'key': key, 'value': value});
  Future<String?> read({required String key}) => _call<String>('read', {'key': key});
  Future<bool> containsKey({required String key}) async => (await _call<bool>('containsKey', {'key': key}))!;
  Future<void> delete({required String key}) => _call<void>('delete', {'key': key});
  Future<void> deleteAll() => _call<void>('deleteAll');
  Future<Map<Object?, Object?>> readAll() async => (await _call<Map<Object?, Object?>>('readAll'))!;
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: StorageProbe()));
}

class StorageProbe extends StatefulWidget {
  const StorageProbe({super.key});
  @override
  State<StorageProbe> createState() => _StorageProbeState();
}

class _StorageProbeState extends State<StorageProbe> {
  String _result = '准备验证；仅使用专用测试键，不读取或显示用户凭据。';
  bool _busy = false;
  String _stage = '开始';

  Future<void> _run(Future<String> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await action();
      if (mounted) setState(() => _result = result);
    } on PlatformException catch (error) {
      if (mounted) setState(() => _result = '平台验证失败：$_stage / ${error.code} / ${error.details is num ? error.details : "无数值错误码"}');
    } catch (error) {
      if (mounted) setState(() => _result = '验证失败：${error.runtimeType}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _expect(bool condition) {
    if (!condition) throw StateError('存储断言不满足');
  }

  Future<String> _writeAndCheck() async {
    // 单独核对原库接线，仅操作专用测试键，并立即删除。
    _stage = '原库写入';
    await _originalStore.write(key: _temporaryKey, value: _value);
    _stage = '原库读取';
    _expect(await _originalStore.read(key: _temporaryKey) == _value);
    await _originalStore.delete(key: _temporaryKey);
    _stage = '隔离库验证';
    await _store.deleteAll();
    _expect((await _store.readAll()).isEmpty);
    await _store.delete(key: _temporaryKey);
    _expect(await _store.read(key: _temporaryKey) == null);
    _expect(!await _store.containsKey(key: _temporaryKey));
    await _store.write(key: _key, value: _value);
    _expect(await _store.read(key: _key) == _value);
    _expect(await _store.containsKey(key: _key));
    _expect((await _store.readAll())[_key] == _value);
    await _store.write(key: _temporaryKey, value: '初始测试值');
    await _store.write(key: _temporaryKey, value: '覆盖测试值');
    _expect(await _store.read(key: _temporaryKey) == '覆盖测试值');
    final longValue = List.filled(20000, '鲸').join();
    await _store.write(key: _temporaryKey, value: longValue);
    _expect(await _store.read(key: _temporaryKey) == longValue);
    await _store.write(key: _temporaryKey, value: '');
    _expect(await _store.read(key: _temporaryKey) == '');
    await _store.write(key: _temporaryKey, value: null);
    _expect(!await _store.containsKey(key: _temporaryKey));
    return '通过：缺失键、中文与表情写读、存在检查、批量读取、覆盖及删除。持久化测试键已保留，请结束进程后重新启动验证。';
  }

  Future<String> _checkPersisted() async {
    _expect(await _store.read(key: _key) == _value);
    return '通过：保存的测试内容读取一致；若已重启应用，此项证明跨进程持久化。';
  }

  Future<String> _clean() async {
    await _store.delete(key: _key);
    await _store.delete(key: _temporaryKey);
    _expect(await _store.read(key: _key) == null);
    return '通过：专用测试键已清理。';
  }

  Future<String> _openBrowser() async {
    _stage = '外部浏览器';
    final uri = Uri.parse('https://github.com/ccch1mneyyy/dsh-go');
    try {
      _expect(await launchUrl(uri, mode: LaunchMode.inAppBrowserView));
    } catch (_) {
      _expect(await launchUrl(uri, mode: LaunchMode.externalApplication));
    }
    return '系统已接受打开请求；仍需观察浏览器是否显示目标页面。';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('鸿蒙安全存储验证')),
    body: Center(
      child: SizedBox(
        width: 600,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(_result),
            const SizedBox(height: 24),
            ElevatedButton(onPressed: _busy ? null : () => _run(_writeAndCheck), child: const Text('写入并验证')),
            ElevatedButton(onPressed: _busy ? null : () => _run(_checkPersisted), child: const Text('重启后验证')),
            ElevatedButton(onPressed: _busy ? null : () => _run(_clean), child: const Text('清理测试键')),
            ElevatedButton(onPressed: _busy ? null : () => _run(_openBrowser), child: const Text('验证浏览器跳转')),
          ],
        ),
      ),
    ),
  );
}
