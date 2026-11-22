/// 飞牛 fnconnect 连接目标：用户只输入一个 ID（如 `mynas`）就能定位到
/// `https://mynas.fnos.net` 上、位于飞牛统一网关
/// `/app/deepseek-harness/fngateway` 的 DSH（HTTP 与 WebSocket 都走这个前缀）。
library;

/// 飞牛 fnconnect 的域名后缀：ID `mynas` → `mynas.fnos.net`。
const fnConnectDomainSuffix = '.fnos.net';

/// DSH 在飞牛统一网关下的默认挂载路径（应用中心 / fpk 安装的 DSH）。
const defaultDshGatewayPath = '/app/deepseek-harness/fngateway';

/// 常见的 DSH 网关/反代路径示例，给「高级」设置当提示用。
///
/// 不同 DSH 安装方式暴露的位置不同：
/// * 应用中心（fpk）安装：飞牛统一网关 `fngateway` 反代，默认
///   `/app/deepseek-harness/fngateway`；
/// * 手动在飞牛「反向代理」里指向 DSH 自带端口：路径就是你自己写的，
///   例如 `/dsh`、`/deepseek`；
/// * 反代到应用根路径：`/app/deepseek-harness`；
/// * 直接端口（fnconnect 允许时）：把完整地址 `https://<id>.fnos.net:<port>/`
///   填在 ID 框里即可，路径留空。
const commonDshGatewayPaths = [defaultDshGatewayPath, '/app/deepseek-harness', '/dsh', '/deepseek'];

/// 只接受 `https`：飞牛会话 Cookie 是凭据，不能走明文。
const _fnConnectScheme = 'https';

/// 一个合法的 fnconnect ID / DNS label（小写字母或数字开头结尾，可含 `-`）。
final _fnconnectLabel = RegExp(r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$');

/// `<label>.fnos.net`。
final _fnconnectHost = RegExp(r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.fnos\.net$');

/// 输入里任何空白都算非法：粘贴时带上空格/换行是常见错误，直接拒绝比猜好。
final _whitespace = RegExp(r'\s');

/// 输入里不允许的控制字符和 URL 里不该直接出现的字符（`<`、引号、`\` 等）。
/// `Uri.tryParse` 会把其中一些百分号编码后照样解析，必须在解析前挡掉。
final _illegalInputCharacters = RegExp(r'''[<>\x00-\x1F\x7F"'`{}|\\^]''');

final _schemePrefix = RegExp(r'^([a-zA-Z][a-zA-Z0-9+.-]*)://');

/// 网关路径允许的字符（RFC 3986 的 pchar 加 `/`），挡掉 `<`、`"` 之类。
final _pathCharacters = RegExp(r"^/[A-Za-z0-9\-._~%!$&'()*+,;=:@/]*$");

/// 解析后的飞牛 fnconnect 目标。
///
/// 由 [parseFnConnectInput] 产生，不要直接构造（字段之间的一致性由解析保证）。
class FnConnectTarget {
  const FnConnectTarget({
    required this.fnconnectId,
    required this.host,
    required this.origin,
    required this.dshBaseUri,
  });

  /// 飞牛 fnconnect ID，如 `mynas`。
  final String fnconnectId;

  /// 网关看到的公开主机名（默认 `mynas.fnos.net`；显式非 443 端口时含端口）。
  ///
  /// 作为 DSH 客户端的 `Host` 头：DSH 的 host fence 按它放行。
  final String host;

  /// 飞牛登录页与 WebView 所在的源：`https://mynas.fnos.net`。
  final Uri origin;

  /// DSH 的 HTTP / WebSocket 基地址，默认
  /// `https://mynas.fnos.net/app/deepseek-harness/fngateway`。
  final Uri dshBaseUri;

  /// 首次登录要打开的页面：飞牛登录入口就在源上。
  Uri get loginUri => origin;

  /// DSH 网关路径（`dshBaseUri.path`），可在「高级」里改。
  String get gatewayPath => dshBaseUri.path;

  /// 同一台 NAS，换成另一个网关路径；非法路径返回 null。
  FnConnectTarget? withGatewayPath(String path) {
    final normalized = normalizeDshGatewayPath(path);
    if (normalized == null) return null;
    return parseFnConnectInput(fnconnectId, gatewayPath: normalized);
  }

  @override
  String toString() => 'FnConnectTarget($fnconnectId → $dshBaseUri)';
}

/// 规范化用户填的网关路径：空 / null 表示用 [defaultDshGatewayPath]；
/// 补前导 `/`、去掉末尾 `/`。非法路径返回 null。
String? normalizeDshGatewayPath(String? raw) {
  final text = (raw ?? '').trim();
  if (text.isEmpty) return defaultDshGatewayPath;
  var path = text.startsWith('/') ? text : '/$text';
  while (path.length > 1 && path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  if (!_pathCharacters.hasMatch(path)) return null;
  return path;
}

/// 把用户输入解析成 [FnConnectTarget]，非法输入返回 null。
///
/// 接受：
/// * `mynas`（裸 ID，补成 `mynas.fnos.net`）
/// * `mynas.fnos.net`
/// * `https://mynas.fnos.net`
/// * 带路径的完整 URL，如
///   `https://mynas.fnos.net/app/deepseek-harness/fngateway`；
///   此时用它的源加该路径。
///
/// 输入里没有路径时用 [gatewayPath]（见 [normalizeDshGatewayPath]），没有给就用
/// [defaultDshGatewayPath]。
///
/// 拒绝：空串、含空白（调用方如需容错请先 trim）、非 `https`、
/// 不是 `<id>.fnos.net` 的主机、非法路径字符。
///
/// query 和 fragment 会被忽略：网关地址只由源和路径决定。
FnConnectTarget? parseFnConnectInput(String raw, {String? gatewayPath}) {
  final customPath = gatewayPath == null ? null : normalizeDshGatewayPath(gatewayPath);
  if (gatewayPath != null && customPath == null) return null;
  if (raw.isEmpty || _whitespace.hasMatch(raw) || _illegalInputCharacters.hasMatch(raw)) return null;

  var text = raw;
  final scheme = _schemePrefix.firstMatch(text);
  if (scheme != null) {
    if (scheme.group(1)!.toLowerCase() != _fnConnectScheme) return null;
  } else {
    // 没写 scheme：允许 "id"、"id.fnos.net"、"id.fnos.net/path"。
    final slash = text.indexOf('/');
    final authority = slash < 0 ? text : text.substring(0, slash);
    if (authority.isEmpty) return null;
    if (!authority.contains('.')) {
      // 裸 fnconnect ID。
      final id = authority.toLowerCase();
      if (!_fnconnectLabel.hasMatch(id)) return null;
      text = '$_fnConnectScheme://$id$fnConnectDomainSuffix${slash < 0 ? '' : text.substring(slash)}';
    } else if (authority.toLowerCase().endsWith(fnConnectDomainSuffix)) {
      text = '$_fnConnectScheme://$text';
    } else {
      return null;
    }
  }

  final uri = Uri.tryParse(text);
  if (uri == null || uri.scheme.toLowerCase() != _fnConnectScheme) return null;
  if (uri.userInfo.isNotEmpty) return null;
  if (!uri.hasAuthority || uri.host.isEmpty) return null;

  final host = uri.host.toLowerCase();
  if (!_fnconnectHost.hasMatch(host)) return null;
  final id = host.substring(0, host.length - fnConnectDomainSuffix.length);

  var path = uri.path;
  if (path.isEmpty || path == '/') {
    path = customPath ?? defaultDshGatewayPath;
  } else {
    while (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
  }
  if (!_pathCharacters.hasMatch(path)) return null;

  final port = uri.hasPort && uri.port != 443 ? uri.port : null;
  final origin = Uri(scheme: _fnConnectScheme, host: host, port: port);
  return FnConnectTarget(
    fnconnectId: id,
    host: port == null ? host : '$host:$port',
    origin: origin,
    dshBaseUri: origin.replace(path: path),
  );
}
