// Reading a DeepSeek App chat export.
//
// The app's 设置 → 导出数据 writes `deepseek_data-YYYY-MM-DD.zip`
// (`manifest.json` = `{"export_format_version": 3}`, `user.json`,
// `chat_session_index.json`, `chat_sessions/<uuid>.json` and, beside a session,
// `chat_sessions/<uuid>_files/` with the pictures it carried).
//
// A session file is one object: `{id, title, pinned, inserted_at, updated_at,
// messages: [{id, parent_id, role, status, inserted_at, fragments: [...]}]}`.
// A fragment is one thing that happened in that message: the person's `REQUEST`,
// DeepSeek's `RESPONSE`, the reasoning in `THINK`, the pages it opened
// (`TOOL_OPEN` / `TOOL_SEARCH` / `TOOL_IMAGE_SEARCH`), the files it was handed
// (`FILE`), and the notices (`TIP`, `CONTENT_RISK`, `TEMPLATE_RESPONSE`).
//
// Only the index and the sessions are read; `*_files/` is skipped, because a
// picture cannot be carried into a host session and its bytes are the reason
// these exports run to hundreds of megabytes.

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';

/// Who said it.
enum DeepSeekRole { user, assistant }

/// A page DeepSeek opened or cited.
class DeepSeekSource {
  const DeepSeekSource({required this.title, required this.url, required this.site});

  final String title;
  final String url;
  final String site;

  bool get isEmpty => title.trim().isEmpty && url.trim().isEmpty;
}

/// A file or picture the person attached.
class DeepSeekAttachment {
  const DeepSeekAttachment({required this.name, required this.bytes, required this.isImage});

  final String name;
  final int bytes;
  final bool isImage;
}

/// One message, flattened out of its fragments.
class DeepSeekMessage {
  const DeepSeekMessage({
    required this.role,
    this.text = '',
    this.thinking = '',
    this.searchQueries = const <String>[],
    this.sources = const <DeepSeekSource>[],
    this.attachments = const <DeepSeekAttachment>[],
    this.at,
    this.stopped = false,
  });

  final DeepSeekRole role;

  /// The words: `REQUEST` for the person, `RESPONSE` / `TEMPLATE_RESPONSE` /
  /// `CONTENT_RISK` for DeepSeek.
  final String text;

  /// The `THINK` fragments, joined. Shown folded, never sent as words.
  final String thinking;

  final List<String> searchQueries;
  final List<DeepSeekSource> sources;
  final List<DeepSeekAttachment> attachments;
  final DateTime? at;

  /// The export recorded this answer as `TIMEOUT` / `INCOMPLETE` /
  /// `CONTENT_FILTER` rather than finished.
  final bool stopped;

  bool get isBlank =>
      text.trim().isEmpty &&
      thinking.trim().isEmpty &&
      searchQueries.isEmpty &&
      sources.isEmpty &&
      attachments.isEmpty;
}

/// One conversation from the export.
class DeepSeekChat {
  DeepSeekChat({
    required this.id,
    required this.title,
    required this.messages,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String title;
  final List<DeepSeekMessage> messages;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// The name the imported session takes: the export's title, or the opening
  /// words when DeepSeek had not named it yet.
  String get sessionTitle {
    final named = title.trim();
    if (named.isNotEmpty) return named;
    for (final message in messages) {
      final text = message.text.trim().replaceAll(RegExp(r'\s+'), ' ');
      if (text.isNotEmpty) return text.length <= 24 ? text : '${text.substring(0, 24)}…';
    }
    return 'DeepSeek 对话';
  }

  int get userTurns => messages.where((m) => m.role == DeepSeekRole.user).length;

  /// What is handed to the model on the first turn in the imported session, so
  /// the conversation carries on instead of starting over. Kept to [maxChars]
  /// by dropping the oldest turns first: the recent ones are what a follow-up
  /// question is actually about.
  String contextPreamble({int maxChars = 6000}) {
    if (messages.isEmpty) return '';
    final blocks = <String>[];
    for (final message in messages) {
      final text = message.text.trim();
      if (text.isEmpty) continue;
      final speaker = message.role == DeepSeekRole.user ? '用户' : 'DeepSeek';
      final attachments = message.attachments.isEmpty
          ? ''
          : '\n[附件：${message.attachments.map((a) => a.name).join('、')}]';
      blocks.add('$speaker：$text$attachments');
    }
    if (blocks.isEmpty) return '';
    final kept = <String>[];
    var length = 0;
    for (final block in blocks.reversed) {
      if (length + block.length + 1 > maxChars && kept.isNotEmpty) break;
      kept.insert(0, block);
      length += block.length + 1;
    }
    final omitted = blocks.length - kept.length;
    final head = omitted > 0 ? '（省略更早的 $omitted 条消息）\n' : '';
    return '以下是我们在 DeepSeek App 里的历史对话，请接着它回答我下面的消息，'
        '不要复述这段历史：\n\n$head${kept.join('\n')}\n\n（历史对话结束）';
  }
}

/// A parsed export.
class DeepSeekExport {
  const DeepSeekExport({required this.chats, this.account, this.formatVersion});

  final List<DeepSeekChat> chats;

  /// The masked account line (`user.json`), when the export carried one.
  final String? account;
  final int? formatVersion;

  /// Sessions that carry at least one message, newest first.
  List<DeepSeekChat> get conversations {
    final kept = chats.where((chat) => chat.messages.isNotEmpty).toList()
      ..sort((a, b) {
        final left = a.updatedAt ?? a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final right = b.updatedAt ?? b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return right.compareTo(left);
      });
    return kept;
  }

  /// Reads [path]. Throws [DeepSeekExportException] when the file is not one of
  /// these exports.
  static DeepSeekExport readFromPath(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      throw const DeepSeekExportException(DeepSeekExportProblem.unreadable, 'file is gone');
    }
    final input = InputFileStream(path);
    try {
      final Archive archive;
      try {
        archive = ZipDecoder().decodeStream(input);
      } on Object catch (error) {
        throw DeepSeekExportException(DeepSeekExportProblem.notAnExport, '$error');
      }

      final entries = <String, ArchiveFile>{};
      for (final entry in archive.files) {
        if (!entry.isFile) continue;
        entries[entry.name] = entry;
      }

      int? formatVersion;
      final manifest = entries['manifest.json'];
      if (manifest == null) {
        throw const DeepSeekExportException(DeepSeekExportProblem.notAnExport, 'no manifest.json');
      }
      final manifestJson = _decodeJson(manifest);
      if (manifestJson is Map && manifestJson['export_format_version'] is int) {
        formatVersion = manifestJson['export_format_version'] as int;
      }

      String? account;
      final user = entries['user.json'];
      if (user != null) {
        final userJson = _decodeJson(user);
        if (userJson is Map) account = _accountLine(userJson);
      }

      final chats = <DeepSeekChat>[];
      final names = entries.keys.where((name) => name.startsWith('chat_sessions/') && name.endsWith('.json')).toList()
        ..sort();
      for (final name in names) {
        final json = _decodeJson(entries[name]!);
        if (json is! Map) continue;
        final chat = _readChat(json);
        if (chat != null) chats.add(chat);
      }
      if (chats.isEmpty) {
        throw const DeepSeekExportException(DeepSeekExportProblem.noChats, 'no sessions');
      }
      return DeepSeekExport(chats: chats, account: account, formatVersion: formatVersion);
    } finally {
      input.closeSync();
    }
  }

  static String? _accountLine(Map<dynamic, dynamic> user) {
    final email = user['email'];
    if (email is String && email.trim().isNotEmpty) return email.trim();
    final mobile = user['mobile'];
    if (mobile is Map) {
      final number = mobile['mobile_number'];
      final area = mobile['area_code'];
      if (number is String && number.trim().isNotEmpty) {
        return '${area is String ? area : ''}${number.trim()}';
      }
    }
    return null;
  }

  static Object? _decodeJson(ArchiveFile entry) {
    final bytes = entry.readBytes();
    if (bytes == null) return null;
    try {
      return jsonDecode(utf8.decode(bytes, allowMalformed: true));
    } on Object {
      return null;
    }
  }

  static DeepSeekChat? _readChat(Map<dynamic, dynamic> json) {
    final id = json['id'];
    final raw = json['messages'];
    final messages = <DeepSeekMessage>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is! Map) continue;
        final message = _readMessage(item);
        if (message != null) messages.add(message);
      }
    }
    return DeepSeekChat(
      id: id is String ? id : '',
      title: json['title'] is String ? (json['title'] as String) : '',
      messages: messages,
      createdAt: _time(json['inserted_at']),
      updatedAt: _time(json['updated_at']),
    );
  }

  static DeepSeekMessage? _readMessage(Map<dynamic, dynamic> json) {
    final role = switch (json['role']) {
      'USER' => DeepSeekRole.user,
      'ASSISTANT' => DeepSeekRole.assistant,
      _ => null,
    };
    if (role == null) return null;
    final text = StringBuffer();
    final thinking = StringBuffer();
    final queries = <String>[];
    final sources = <DeepSeekSource>[];
    final attachments = <DeepSeekAttachment>[];
    final raw = json['fragments'];
    if (raw is List) {
      for (final item in raw) {
        if (item is! Map) continue;
        switch (item['type']) {
          case 'REQUEST':
          case 'RESPONSE':
          case 'TEMPLATE_RESPONSE':
          case 'CONTENT_RISK':
            final content = item['content'];
            if (content is String && content.trim().isNotEmpty) {
              if (text.isNotEmpty) text.write('\n\n');
              text.write(content.trim());
            }
          case 'THINK':
            final content = item['content'];
            if (content is String && content.trim().isNotEmpty) {
              if (thinking.isNotEmpty) thinking.write('\n\n');
              thinking.write(content.trim());
            }
          case 'TIP':
            final content = item['content'];
            if (content is String && content.trim().isNotEmpty) text.write(content.trim());
          case 'TOOL_SEARCH':
            final list = item['queries'];
            if (list is List) {
              for (final query in list) {
                if (query is String && query.trim().isNotEmpty) queries.add(query.trim());
              }
            }
            _addSources(item['results'], sources);
          case 'TOOL_IMAGE_SEARCH':
            _addSources(item['results'], sources);
          case 'TOOL_OPEN':
            final url = item['url'];
            if (url is String && url.trim().isNotEmpty) {
              sources.add(DeepSeekSource(
                title: item['title'] is String ? item['title'] as String : '',
                url: url.trim(),
                site: item['site_name'] is String ? item['site_name'] as String : '',
              ));
            }
          case 'FILE':
            final list = item['files'];
            if (list is List) {
              for (final file in list) {
                if (file is! Map) continue;
                final name = file['file_name'];
                if (name is! String || name.trim().isEmpty) continue;
                final size = file['file_size'];
                attachments.add(DeepSeekAttachment(
                  name: name.trim(),
                  bytes: size is int ? size : 0,
                  isImage: file['is_image'] == true,
                ));
              }
            }
        }
      }
    }
    final message = DeepSeekMessage(
      role: role,
      text: text.toString(),
      thinking: thinking.toString(),
      searchQueries: queries,
      sources: sources,
      attachments: attachments,
      at: _time(json['inserted_at']),
      stopped: switch (json['status']) {
        'TIMEOUT' || 'INCOMPLETE' || 'CONTENT_FILTER' => true,
        _ => false,
      },
    );
    return message.isBlank ? null : message;
  }

  static void _addSources(Object? results, List<DeepSeekSource> into) {
    if (results is! List) return;
    for (final result in results) {
      if (result is! Map) continue;
      final url = result['url'];
      if (url is! String || url.trim().isEmpty) continue;
      final seeded = DeepSeekSource(
        title: result['title'] is String ? result['title'] as String : '',
        url: url.trim(),
        site: result['site_name'] is String ? result['site_name'] as String : '',
      );
      if (into.any((existing) => existing.url == seeded.url)) continue;
      into.add(seeded);
    }
  }

  static DateTime? _time(Object? value) {
    if (value is! String || value.isEmpty) return null;
    return DateTime.tryParse(value)?.toLocal();
  }
}

/// What went wrong reading an export.
enum DeepSeekExportProblem {
  /// Not a ZIP, or no `manifest.json` in it.
  notAnExport,

  /// A DeepSeek export, but with no conversation in it.
  noChats,

  unreadable,
}

class DeepSeekExportException implements Exception {
  const DeepSeekExportException(this.problem, this.detail);

  final DeepSeekExportProblem problem;
  final String detail;

  @override
  String toString() => 'DeepSeekExportException(${problem.name}, $detail)';
}
