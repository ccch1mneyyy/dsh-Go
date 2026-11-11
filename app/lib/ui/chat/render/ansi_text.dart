// Portions derived from PiPilot (https://github.com/CikeSeven/pi_pilot), MIT, Copyright (c) 2026 CikeSeven. See THIRD_PARTY_NOTICES.md.

import 'package:flutter/material.dart';

import '../../theme/semantic_colors.dart';

/// CSI 序列(ESC[ ... 终结字节)。非 SGR(终结字节非 m)一律剥离不渲染。
final _csi = RegExp('\x1B\\[([0-9;?]*)([A-Za-z])');

/// OSC 序列(ESC] ... BEL / ESC\),如终端标题、超链接。直接剥离。
final _osc = RegExp('\x1B\\][^\x07\x1B]*(?:\x07|\x1B\\\\)');

/// 去掉所有 ANSI 转义(复制 / 纯文本场景用)。
String stripAnsi(String input) => input.replaceAll(_osc, '').replaceAll(_csi, '');

/// 文本里有没有 ANSI 转义(没有就走纯文本快路径)。
bool hasAnsi(String input) => input.contains('\x1B');

/// 去掉 OSC 序列,留下 SGR 着色。
String stripOsc(String input) => input.replaceAll(_osc, '');

/// 一个 CSI 转义最长也就这么多(38;2;r;g;b 加终结字节)。
const _csiSpan = 24;

/// 一个 OSC 序列(超链接的地址在里面)往后最多找这么远的终结符。
const _oscSpan = 4096;

/// [index] 落在一个转义序列中间时,序列的 (起点, 终点后一位);否则 null。
/// 截断长文本时用:序列要么整个留下,要么整个不要。
(int, int)? ansiEscapeAround(String text, int index) {
  if (index <= 0 || index >= text.length) return null;
  final esc = text.lastIndexOf('\x1B', index - 1);
  if (esc < 0 || esc + 1 >= text.length) return null;
  final kind = text.codeUnitAt(esc + 1);
  if (kind == 0x5D) {
    // OSC:到 BEL 或 ST(ESC \)才算完,中间的字母不是终结符。
    final limit = esc + _oscSpan < text.length ? esc + _oscSpan : text.length;
    for (var i = esc + 2; i < limit; i++) {
      final c = text.codeUnitAt(i);
      if (c == 0x07) return i >= index ? (esc, i + 1) : null;
      if (c == 0x1B) {
        final st = i + 1 < text.length && text.codeUnitAt(i + 1) == 0x5C;
        final end = st ? i + 2 : i;
        return end > index ? (esc, end) : null;
      }
    }
    return null;
  }
  // ST 的那个 ESC:[index] 夹在 ESC 和 \ 之间。
  if (kind == 0x5C) return index == esc + 1 ? (esc, esc + 2) : null;
  if (kind != 0x5B || index - esc > _csiSpan) return null;
  for (var i = esc + 2; i < text.length && i - esc <= _csiSpan; i++) {
    final c = text.codeUnitAt(i);
    final letter = (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);
    if (letter) return i >= index ? (esc, i + 1) : null;
  }
  return (esc, index);
}

/// 顺着文本走一遍 SGR 序列,记住「到这里为止还生效的那些」。
///
/// 把一段着色文本从中间切开单独渲染时(截断后的尾部、全文页的每一行),
/// 在这一段前面补上 [prefix],颜色就和连着渲染时一样。只看转义序列,
/// 不建 TextSpan,代价按序列个数算,和文本长度无关。
class SgrCarry {
  final _active = <String>[];
  String? _prefix = '';

  /// 途中遇到的 CSI 序列(着色和非着色的)一共占了多少字。
  int escapeChars = 0;

  /// 最多带这么多条:状态只有前景、背景和三个字形开关,最近的这些足够重建。
  static const _maxActive = 48;

  /// 走过 [source] 的 [start, end)。
  void advance(String source, int start, int end) {
    for (var i = source.indexOf('\x1B', start); i >= 0 && i < end; i = source.indexOf('\x1B', i + 1)) {
      final m = _csi.matchAsPrefix(source, i);
      if (m == null || m.end > end) continue;
      escapeChars += m.end - m.start;
      if (m[2] != 'm') continue;
      final params = m[1]!;
      final reset = params.isEmpty || params == '0';
      if (reset || params.startsWith('0;')) _active.clear();
      if (!reset) {
        if (_active.length == _maxActive) _active.removeAt(0);
        _active.add(m[0]!);
      }
      _prefix = null;
    }
  }

  /// 补在后面一段文本前的序列;没有生效的着色时是空串。
  String get prefix => _prefix ??= _active.join();
}

class _SgrState {
  Color? fg;
  Color? bg;
  bool bold = false;
  bool italic = false;
  bool underline = false;

  void reset() {
    fg = null;
    bg = null;
    bold = false;
    italic = false;
    underline = false;
  }

  TextStyle apply(TextStyle base) => base.copyWith(
    color: fg ?? base.color,
    backgroundColor: bg ?? base.backgroundColor,
    fontWeight: bold ? FontWeight.w600 : base.fontWeight,
    fontStyle: italic ? FontStyle.italic : base.fontStyle,
    decoration: underline ? TextDecoration.underline : base.decoration,
  );
}

/// 解析 SGR 着色文本为 TextSpan。[ansi16] 为 SGR 30-37 / 90-97 色板。
TextSpan parseAnsi(String input, TextStyle base, List<Color> ansi16) {
  final source = input.replaceAll(_osc, '');
  if (!hasAnsi(source)) return TextSpan(text: source, style: base);
  final children = <TextSpan>[];
  final sgr = _SgrState();
  var last = 0;
  void flushText(int end) {
    if (end > last) {
      children.add(TextSpan(text: source.substring(last, end), style: sgr.apply(base)));
    }
  }

  for (final m in _csi.allMatches(source)) {
    flushText(m.start);
    last = m.end;
    if (m[2] != 'm') continue;
    final params = (m[1]!.isEmpty ? '0' : m[1]!).split(';').map((s) => int.tryParse(s) ?? 0).toList();
    var i = 0;
    while (i < params.length) {
      final code = params[i];
      switch (code) {
        case 0:
          sgr.reset();
        case 1:
          sgr.bold = true;
        case 3:
          sgr.italic = true;
        case 4:
          sgr.underline = true;
        case 22:
          sgr.bold = false;
        case 23:
          sgr.italic = false;
        case 24:
          sgr.underline = false;
        case 39:
          sgr.fg = null;
        case 49:
          sgr.bg = null;
        case >= 30 && <= 37:
          sgr.fg = ansi16[code - 30];
        case >= 90 && <= 97:
          sgr.fg = ansi16[code - 82];
        case >= 40 && <= 47:
          sgr.bg = ansi16[code - 40].withValues(alpha: 0.18);
        case >= 100 && <= 107:
          sgr.bg = ansi16[code - 92].withValues(alpha: 0.18);
        case 38 || 48:
          final (color, consumed) = _extendedColor(params, i, ansi16);
          if (code == 38) {
            sgr.fg = color ?? sgr.fg;
          } else {
            sgr.bg = color?.withValues(alpha: 0.18) ?? sgr.bg;
          }
          i += consumed;
        default:
          break;
      }
      i++;
    }
  }
  flushText(source.length);
  return TextSpan(style: base, children: children);
}

/// 38;5;n(xterm256)/ 38;2;r;g;b(truecolor)。返回 (颜色, 额外消耗的参数个数)。
(Color?, int) _extendedColor(List<int> params, int i, List<Color> ansi16) {
  if (i + 1 >= params.length) return (null, 0);
  switch (params[i + 1]) {
    case 5:
      if (i + 2 >= params.length) return (null, 1);
      return (_xterm256(params[i + 2], ansi16), 2);
    case 2:
      if (i + 4 >= params.length) return (null, params.length - i - 1);
      return (
        Color.fromARGB(255, params[i + 2].clamp(0, 255), params[i + 3].clamp(0, 255), params[i + 4].clamp(0, 255)),
        4,
      );
    default:
      return (null, 0);
  }
}

Color? _xterm256(int n, List<Color> ansi16) {
  if (n < 0 || n > 255) return null;
  if (n < 16) return ansi16[n];
  if (n < 232) {
    // 6×6×6 色立方
    final v = n - 16;
    const steps = [0, 95, 135, 175, 215, 255];
    return Color.fromARGB(255, steps[v ~/ 36], steps[(v % 36) ~/ 6], steps[v % 6]);
  }
  final gray = 8 + (n - 232) * 10;
  return Color.fromARGB(255, gray, gray, gray);
}

/// 带 ANSI 着色的可选中文本;按 (text, 色板) 记忆化解析结果。
///
/// 只能铺在代码井([DshColors.codeWellBg])上:ANSI 色板是按井底调的对比度。
class AnsiText extends StatefulWidget {
  const AnsiText({super.key, required this.text, required this.style});

  final String text;
  final TextStyle style;

  @override
  State<AnsiText> createState() => _AnsiTextState();
}

class _AnsiTextState extends State<AnsiText> {
  TextSpan? _span;
  String? _parsedText;
  TextStyle? _parsedStyle;
  List<Color>? _parsedPalette;

  @override
  Widget build(BuildContext context) {
    final palette = DshColors.of(context).ansi;
    if (_span == null ||
        _parsedText != widget.text ||
        _parsedStyle != widget.style ||
        !identical(_parsedPalette, palette)) {
      _span = parseAnsi(widget.text, widget.style, palette);
      _parsedText = widget.text;
      _parsedStyle = widget.style;
      _parsedPalette = palette;
    }
    return SelectableText.rich(_span!);
  }
}
