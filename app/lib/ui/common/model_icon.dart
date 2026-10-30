import 'package:flutter/material.dart';

import '../theme/app_icons.dart';

/// Match the original ID first, then the display name. Channels and shortened
/// names are deliberately excluded: a gateway can serve many model families.
String? modelIconBrand(String id, String name) {
  for (final value in [id.toLowerCase(), name.toLowerCase()]) {
    for (final rule in _modelIconRules.entries) {
      if (rule.value.hasMatch(value)) return rule.key;
    }
  }
  return null;
}

// Specific families precede overlapping names (ChatGLM/GLM, Hailuo/MiniMax,
// DeepSeek distillations/Qwen). Short names require a word/version boundary.
final _modelIconRules = <String, RegExp>{
  'deepseek': RegExp(r'deepseek|深度求索'),
  'chatglm': RegExp(r'chatglm'),
  'cogview': RegExp(r'cogview'),
  'cogvideo': RegExp(r'cogvideo'),
  'hailuo': RegExp(r'hailuo|海螺'),
  'sora': RegExp(r'sora'),
  'dalle': RegExp(r'dall[-· ]?e'),
  'flux': RegExp(r'flux'),
  'stability': RegExp(r'stable[-_ ]?diffusion|stability|sdxl|\bsd3(?:\b|\d)'),
  'midjourney': RegExp(r'midjourney'),
  'ideogram': RegExp(r'ideogram'),
  'recraft': RegExp(r'recraft'),
  'runway': RegExp(r'runway|\bgen[-_ ]\d'),
  'luma': RegExp(r'luma|\bray[-_ ]?\d'),
  'pika': RegExp(r'pika'),
  'adobefirefly': RegExp(r'firefly'),
  'elevenlabs': RegExp(r'elevenlabs|eleven[_-](?:v\d|multilingual|turbo|flash)'),
  'suno': RegExp(r'suno'),
  'udio': RegExp(r'(^|[^a-z0-9])udio(?=$|[-_ ./:]|\d)'),
  'kling': RegExp(r'kling|可灵'),
  'kolors': RegExp(r'kolors|可图'),
  'vidu': RegExp(r'vidu'),
  'qwen': RegExp(r'qwen|qwq|qvq|tongyi|千问|通义'),
  'kimi': RegExp(r'kimi|moonshot|月之暗面'),
  'zhipu': RegExp(r'glm|zhipu|智谱'),
  'doubao': RegExp(r'doubao|豆包|seedance|seedream|(^|[^a-z0-9])seed(?=$|[-_ ./:]|\d)'),
  'minimax': RegExp(r'minimax|abab'),
  'stepfun': RegExp(r'stepfun|(^|[^a-z0-9])step(?=$|[-_ ./:]|\d)|阶跃'),
  'hunyuan': RegExp(r'hunyuan|混元'),
  'wenxin': RegExp(r'ernie|wenxin|文心'),
  'spark': RegExp(r'spark|星火'),
  'baichuan': RegExp(r'baichuan|百川'),
  'yi': RegExp(r'(^|[^a-z0-9])yi(?=$|[-_ ./:]|\d)|零一万物'),
  'internlm': RegExp(r'internlm|书生|浦语'),
  'longcat': RegExp(r'longcat'),
  'xiaomimimo': RegExp(r'mimo'),
  'rwkv': RegExp(r'rwkv'),
  'sensenova': RegExp(r'sensenova|日日新'),
  'skywork': RegExp(r'skywork'),
  'ling': RegExp(r'(^|[^a-z0-9])ling(?=$|[-_ ./:]|\d)|百灵'),
  'claude': RegExp(r'claude'),
  'gemini': RegExp(r'gemini'),
  'gemma': RegExp(r'gemma'),
  'grok': RegExp(r'grok'),
  'meta': RegExp(r'llama'),
  'mistral': RegExp(r'mistral|mixtral|ministral|codestral|devstral|magistral|pixtral'),
  'cohere': RegExp(r'cohere|command(?:[-_ ]|$)|embed[-_](?:english|multilingual)'),
  'perplexity': RegExp(r'sonar'),
  'ai21': RegExp(r'jamba'),
  'nousresearch': RegExp(r'hermes'),
  'deepcogito': RegExp(r'cogito'),
  'inception': RegExp(r'mercury'),
  'openai': RegExp(r'gpt|(^|[^a-z0-9])o[134](?=$|[-_ ./:])'),
};

/// Local model artwork; unrecognised models and missing assets use the app glyph.
class ModelIcon extends StatelessWidget {
  const ModelIcon({super.key, required this.id, required this.name, this.size = 20});

  final String id;
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brand = modelIconBrand(id, name);
    final fallback = Icon(AppIcons.model, size: size, color: theme.colorScheme.primary);
    return SizedBox.square(
      dimension: size,
      child: brand == null
          ? fallback
          : Image.asset(
              'assets/model_icons/${theme.brightness == Brightness.dark ? 'dark' : 'light'}/$brand.png',
              width: size,
              height: size,
              cacheWidth: (size * (MediaQuery.maybeDevicePixelRatioOf(context) ?? 1)).ceil(),
              fit: BoxFit.contain,
              filterQuality: FilterQuality.medium,
              excludeFromSemantics: true,
              errorBuilder: (context, error, stackTrace) => fallback,
            ),
    );
  }
}
