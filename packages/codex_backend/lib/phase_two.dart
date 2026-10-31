part of 'codex_backend.dart';

extension _CodexPhaseTwo on CodexChatClient {
  Future<String> _filePath(String sessionId, String path) async {
    if (path.contains('\x00')) throw unsupported;
    if (path.startsWith('/')) return path;
    var thread = _threads[sessionId];
    thread ??= obj(
      (await _call('thread/read', {
        'threadId': sessionId,
        'includeTurns': false,
      }))['thread'],
    );
    final base = thread['cwd'] as String? ?? cwd ?? home;
    return '$base/$path';
  }

  Future<RpcResult> _fileCall(
    String endpoint,
    Map<String, Object?> args,
  ) async {
    if (files == null) return const RpcError(unsupported);
    try {
      final path = await _filePath(
        args['workspaceFileScopeId'] as String,
        args['path'] as String,
      );
      if (endpoint == 'workspaceFiles/stat')
        return RpcOk(await files!.stat(path));
      if (endpoint == 'workspaceFiles/read') {
        final stat = await files!.stat(path);
        const cap = 2 * 1024 * 1024;
        if (stat['bytes'] is! int || (stat['bytes'] as int) > cap) {
          return const RpcError(
            DshRemoteException(
              'workspace-file/too-large',
              '文本预览限 2 MiB；可以下载后打开',
            ),
          );
        }
        final bytes = await files!.read(path, 0, cap);
        String text;
        try {
          text = utf8.decode(bytes);
        } on FormatException {
          return const RpcError(
            DshRemoteException('workspace-file/not-text', '不是 UTF-8 文本'),
          );
        }
        if (text.contains('\x00'))
          return const RpcError(
            DshRemoteException('workspace-file/not-text', '不是文本文件'),
          );
        final range = obj(args['range']);
        final offset = ((range['offset'] as num?)?.toInt() ?? 1).clamp(
          1,
          1 << 30,
        );
        final limit = ((range['limit'] as num?)?.toInt() ?? 500).clamp(1, 5000);
        final lines = const LineSplitter().convert(text);
        final page = lines.skip(offset - 1).take(limit).toList();
        return RpcOk({
          ...stat,
          'text': page.join('\n'),
          'lines': page.length,
          'offset': offset,
          'eof': offset - 1 + page.length >= lines.length,
        });
      }
      if (endpoint == 'workspaceFiles/readBytes') {
        final range = obj(obj(args['options'])['range']);
        final offset = (range['offset'] as num).toInt();
        final length = (range['length'] as num).toInt();
        final stat = await files!.stat(path);
        final bytes = await files!.read(path, offset, length);
        return RpcOk({
          ...stat,
          'offset': offset,
          'data': bytes,
          'eof':
              bytes.length < length ||
              (stat['bytes'] is int &&
                  offset + bytes.length >= (stat['bytes'] as int)),
        });
      }
      return const RpcError(unsupported);
    } catch (e) {
      return RpcError(
        DshRemoteException('workspace-file/read-failed', '无法读取远程文件：$e'),
      );
    }
  }

  void _setUsage(String id, Map<String, dynamic> usage) {
    final total = obj(usage['total']);
    final last = obj(usage['last']);
    int n(Map<String, dynamic> m, String k) => (m[k] as num?)?.toInt() ?? 0;
    final cache = n(total, 'cachedInputTokens');
    final write = n(total, 'cacheWriteInputTokens');
    final values = <String, Object?>{
      'tokenUsage': <String, Object?>{
        'uncachedInputTokens': (n(total, 'inputTokens') - cache - write).clamp(
          0,
          1 << 62,
        ),
        'cacheReadTokens': cache,
        'cacheWriteTokens': write,
        'outputTokens': n(total, 'outputTokens'),
      },
      'contextPressure': <String, Object?>{
        'pressureTokens': n(last, 'totalTokens'),
        if (usage['modelContextWindow'] != null)
          'contextWindow': usage['modelContextWindow'],
      },
    };
    _usage[id] = values;
    final seq = ++_usageSeq;
    for (final entry in values.entries) {
      _controlEvents.add(
        SessionControlProjection(id, entry.key, entry.value, seq),
      );
    }
  }

  Future<void> _seedUsage(String id, Map<String, dynamic> t) async {
    if (files == null || t['path'] == null || _usage.containsKey(id)) return;
    try {
      final result = await files!.inspect({
        'usage': true,
        'threads': [
          {'id': id, 'path': t['path']},
        ],
      });
      if (_closed || _usage.containsKey(id)) return;
      final info = obj(result['usage']);
      if (info.isEmpty) return;
      Map<String, dynamic> convert(Object? value) {
        final m = obj(value);
        return {
          'totalTokens': m['total_tokens'],
          'inputTokens': m['input_tokens'],
          'cachedInputTokens': m['cached_input_tokens'],
          'cacheWriteInputTokens': m['cache_write_input_tokens'],
          'outputTokens': m['output_tokens'],
        };
      }

      _setUsage(id, {
        'total': convert(info['total_token_usage']),
        'last': convert(info['last_token_usage']),
        'modelContextWindow': info['model_context_window'],
      });
    } catch (_) {
      /* Unsupported/cold histories stay unavailable, not estimated. */
    }
  }
}

List<Map<String, dynamic>> _userContent(Map<String, dynamic> item) {
  final result = <Map<String, dynamic>>[];
  final content = rows(item['content']);
  for (var i = 0; i < content.length; i++) {
    final c = content[i];
    if (c['type'] == 'localImage' || c['type'] == 'image') {
      final path = c['path'] as String?;
      result.add({
        'type': 'image',
        'attachment': {
          'attachmentId': 'codex-image:${item['id']}:$i',
          'mediaType': _imageMime(path ?? c['url']?.toString() ?? ''),
          'name': path?.split('/').last ?? 'image',
        },
      });
    } else if (c['type'] == 'text') {
      var text = c['text'] as String? ?? '';
      final files = <Map<String, dynamic>>[];
      text = text.replaceAllMapped(
        RegExp(
          r'\n\n\[附件：([^\]\n]+)\]\(<([^>\n]+/\.dsh-go-uploads/[^>\n]+)>\)',
        ),
        (m) {
          files.add({
            'type': 'file',
            'attachment': {'attachmentId': m[2], 'name': m[1], 'path': m[2]},
          });
          return '';
        },
      );
      if (text.isNotEmpty) result.add({...c, 'text': text});
      result.addAll(files);
    }
  }
  return result;
}

String _imageMime(String path) {
  if (path.startsWith('data:')) return path.substring(5).split(';').first;
  return switch (path.toLowerCase().split('.').last) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    _ => 'image/png',
  };
}

List<Map<String, dynamic>> _toolImages(Map<String, dynamic> item) {
  final content = item['type'] == 'imageView'
      ? <Map<String, dynamic>>[
          {'type': 'inputImage', 'imageUrl': item['path']},
        ]
      : rows(item['contentItems']);
  return [
    for (var i = 0; i < content.length; i++)
      if (content[i]['type'] == 'inputImage')
        {
          'type': 'image',
          'attachment': {
            'attachmentId': 'codex-tool:${item['id']}:$i',
            'mediaType': _imageMime(content[i]['imageUrl']?.toString() ?? ''),
            'name': 'image',
          },
        },
  ];
}
