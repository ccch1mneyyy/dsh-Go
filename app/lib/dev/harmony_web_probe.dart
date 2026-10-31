// 独立网页能力探针：只加载本地HTML，不连接DSH、不读凭据。
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: HarmonyWebProbe()));
}

class HarmonyWebProbe extends StatefulWidget {
  const HarmonyWebProbe({super.key});

  @override
  State<HarmonyWebProbe> createState() => _HarmonyWebProbeState();
}

class _HarmonyWebProbeState extends State<HarmonyWebProbe> {
  late final WebViewController _controller;
  String _result = '等待本地网页报告引擎能力。';
  String _fileResult = '附件探针尚未运行。';
  bool _picking = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController();
    _open();
  }

  Future<void> _open() async {
    try {
      await _controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await _controller.addJavaScriptChannel('DshWebProbe', onMessageReceived: (message) {
        if (mounted) setState(() => _result = message.message);
      });
      await _controller.loadHtmlString(_html);
    } catch (_) {
      if (mounted) setState(() => _result = '本地网页探针加载失败。');
    }
  }

  Future<void> _pickFile() async {
    if (_picking) return;
    setState(() {
      _picking = true;
      _fileResult = '正在打开系统文件选择器；仅选择测试夹具。';
    });
    try {
      final selected = await FilePicker.pickFile();
      if (mounted) setState(() => _fileResult = selected == null ? '已取消选择。' : '选择结果已返回；未读取内容。');
    } on PlatformException catch (error) {
      if (mounted) setState(() => _fileResult = '附件错误：${error.code} / ${error.details is num ? error.details : "无数值错误码"}');
    } catch (error) {
      if (mounted) setState(() => _fileResult = '附件错误：DART_${error.runtimeType}');
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('鸿蒙网页能力验证')),
    body: Column(children: [
      const Padding(padding: EdgeInsets.all(12), child: Text('仅本地HTML；没有DSH地址、Cookie或模型请求。')),
      Padding(padding: const EdgeInsets.all(12), child: Text(_result)),
      Padding(padding: const EdgeInsets.all(8), child: Text(_fileResult)),
      ElevatedButton(onPressed: _picking ? null : _pickFile, child: const Text('打开文件选择器（测试夹具）')),
      Expanded(child: WebViewWidget(controller: _controller)),
    ]),
  );
}

const _html = r'''
<!doctype html><html lang="zh"><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>本地网页能力验证</title>
<style>body{font:18px sans-serif;padding:16px;background:#f4f6f9;color:#182535}pre{white-space:pre-wrap;line-height:1.6}button{padding:12px;font:inherit}</style>
<h2>网页引擎能力</h2><p>没有外部网络资源，只查询API类型和浏览器在线标记。</p>
<pre id="result">等待脚本执行</pre><button onclick="report()">重新检查</button>
<script>
function report() {
  var data = {
    'AbortSignal.any': typeof AbortSignal === 'function' ? typeof AbortSignal.any : '不存在',
    'AbortSignal.timeout': typeof AbortSignal === 'function' ? typeof AbortSignal.timeout : '不存在',
    'Promise.withResolvers': typeof Promise.withResolvers,
    'WebSocket': typeof WebSocket,
    'fetch': typeof fetch,
    'ReadableStream': typeof ReadableStream,
    'TextDecoder': typeof TextDecoder,
    'structuredClone': typeof structuredClone,
    'navigator.onLine': navigator.onLine
  };
  var text = JSON.stringify(data, null, 2);
  document.getElementById('result').textContent = text;
  if (window.DshWebProbe) window.DshWebProbe.postMessage(text);
}
report();
</script></html>
''';
