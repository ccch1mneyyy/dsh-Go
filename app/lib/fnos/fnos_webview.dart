/// 飞牛 fnOS 登录页：WebView 里登录一次，抓到会话 Cookie 并验证 DSH 可访问后，
/// 把 Cookie 串交给调用方。
///
/// 文案全部走 l10n（`app/lib/l10n/parts/fnos_*.arb`），页面本身不关心语言。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../l10n/l10n.dart';
import 'fnconnect.dart';
import 'fnos_auth.dart';

/// 读 Cookie 的间隔。
const _cookiePollInterval = Duration(seconds: 1);

/// 整个登录流程的上限。
const _loginTimeout = Duration(minutes: 5);

/// 飞牛 fnOS 账号登录页。
///
/// 打开 [target.origin]，每秒读一次 WebView 的 Cookie；一旦拿到 Cookie 就用
/// [probeFnosDsh] 验证，验证通过时先调用 [onLoggedIn]，再带着 Cookie 串 pop。
/// 用户返回、5 分钟超时都只 pop 不带值。
class FnosLoginPage extends StatefulWidget {
  const FnosLoginPage({super.key, required this.target, required this.onLoggedIn});

  /// 要登录的飞牛 fnconnect 目标。
  final FnConnectTarget target;

  /// 验证通过后的回调（可异步）；页面随后 pop，并把 Cookie 串作为路由结果返回。
  final FutureOr<void> Function(String cookieHeader) onLoggedIn;

  /// 以路由方式打开登录页：成功返回 Cookie 串，用户放弃或超时返回 null。
  static Future<String?> show(BuildContext context, {required FnConnectTarget target}) {
    return Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => FnosLoginPage(target: target, onLoggedIn: (_) {}),
      ),
    );
  }

  @override
  State<FnosLoginPage> createState() => _FnosLoginPageState();
}

class _FnosLoginPageState extends State<FnosLoginPage> {
  WebViewController? _controller;
  Timer? _poll;
  Timer? _deadline;

  /// 同一时刻只跑一个探测。
  bool _probing = false;

  /// 已经拿到可用 Cookie，不再轮询、只 pop 一次。
  bool _finished = false;

  /// 超过 [_loginTimeout]，等用户点「重试」。
  bool _timedOut = false;

  bool _loading = true;

  /// 登录页的主文档已经加载完。
  bool _pageFinished = false;

  /// 轮询/验证过程中的动态提示；null 时由页面按阶段显示默认文案。
  String? _status;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
    _startTimers();
  }

  @override
  void dispose() {
    _stopTimers();
    super.dispose();
  }

  void _startTimers() {
    _poll?.cancel();
    _deadline?.cancel();
    _poll = Timer.periodic(_cookiePollInterval, (_) => unawaited(_checkCookie()));
    _deadline = Timer(_loginTimeout, _onTimeout);
  }

  void _stopTimers() {
    _poll?.cancel();
    _deadline?.cancel();
    _poll = null;
    _deadline = null;
  }

  /// 建 WebView 并打开飞牛登录入口。
  Future<void> _open() async {
    try {
      final controller = WebViewController();
      _controller = controller;
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await controller.setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (!mounted) return;
            _set(() {
              _loading = true;
              _pageFinished = false;
              _status = null;
            });
          },
          onPageFinished: (_) {
            if (!mounted) return;
            _set(() {
              _loading = false;
              _pageFinished = true;
            });
          },
          onWebResourceError: (error) {
            // 主文档失败才提示；子资源（图标、统计）失败不影响登录。
            if (!mounted || error.isForMainFrame != true) return;
            _set(() {
              _loading = false;
              _error = context.l10n.fnosWebLoginLoadFailed;
            });
          },
        ),
      );
      if (!mounted) return;
      await controller.loadRequest(widget.target.origin);
    } catch (error) {
      if (!mounted) return;
      _set(() {
        _loading = false;
        _error = context.l10n.fnosWebLoginUnavailable;
      });
    }
  }

  /// 每秒一次：读到 Cookie 就验证，验证过了就收工。
  Future<void> _checkCookie() async {
    if (_finished || _probing || _timedOut || !mounted) return;
    _probing = true;
    try {
      final cookie = await readFnosCookies(widget.target.origin.toString());
      if (!mounted) return;
      if (cookie == null || _finished || _timedOut) return;
      _setStatus(context.l10n.fnosWebLoginGotCredentials);
      final probe = await probeFnosDsh(target: widget.target, cookieHeader: cookie);
      if (!mounted) return;
      if (_finished || _timedOut) return;
      if (probe.authenticated) {
        await _finish(cookie);
      } else {
        // Cookie 可能刚写入、网关会话还没生效：显示原因但继续等。
        _setStatus(probe.detail ?? context.l10n.fnosWebLoginVerifyFailed);
      }
    } finally {
      _probing = false;
    }
  }

  /// 回调调用方，然后带着 Cookie 串 pop。
  Future<void> _finish(String cookie) async {
    if (_finished) return;
    _finished = true;
    _stopTimers();
    try {
      await widget.onLoggedIn(cookie);
    } catch (error) {
      // 保存失败不阻止把 Cookie 交回上一页；只记类型，绝不打印 Cookie。
      debugPrint('[fnos] onLoggedIn failed: ${error.runtimeType}');
    }
    if (!mounted) return;
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop(cookie);
    } else {
      final connected = context.l10n.fnosWebLoginConnected;
      _set(() => _status = connected);
    }
  }

  void _onTimeout() {
    if (_finished || !mounted) return;
    _timedOut = true;
    _poll?.cancel();
    _poll = null;
    _deadline = null;
    _set(() => _error = context.l10n.fnosWebLoginTimeout);
  }

  void _retry() {
    _set(() {
      _timedOut = false;
      _error = null;
      _status = null;
      _loading = true;
      _pageFinished = false;
    });
    final controller = _controller;
    if (controller != null) {
      unawaited(controller.reload().catchError((Object _) {}));
    } else {
      unawaited(_open());
    }
    _startTimers();
  }

  void _set(VoidCallback changes) {
    if (!mounted) return;
    setState(changes);
  }

  void _setStatus(String status) {
    if (!mounted || _status == status) return;
    _set(() => _status = status);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final error = _error;
    final controller = _controller;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.fnosWebLoginTitle)),
      body: Column(
        children: [
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          _header(theme, l10n),
          if (error != null) _errorBar(theme, l10n, error),
          Expanded(
            child: controller == null
                ? Center(child: Text(error == null ? l10n.fnosWebLoginInitializing : l10n.fnosWebLoginRetryHint))
                : WebViewWidget(controller: controller),
          ),
        ],
      ),
    );
  }

  Widget _header(ThemeData theme, L10n l10n) {
    final status = _status ?? (_pageFinished ? null : l10n.fnosWebLoginOpening);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.fnosWebLoginHint, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
          if (status != null) ...[
            const SizedBox(height: 2),
            Text(status, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ],
      ),
    );
  }

  Widget _errorBar(ThemeData theme, L10n l10n, String error) {
    return Container(
      width: double.infinity,
      color: theme.colorScheme.errorContainer,
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 18, color: theme.colorScheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(error, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onErrorContainer)),
          ),
          TextButton(onPressed: _retry, child: Text(l10n.commonRetry)),
        ],
      ),
    );
  }
}
