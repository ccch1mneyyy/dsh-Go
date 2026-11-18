// The conversations imported from a DeepSeek App export, kept beside the host
// session each of them became.
//
// A host session holds the turns that happen here; what the person said on the
// phone before is ours to keep. One JSON file per session under
// `<app support>/deepseek_import/`, plus `index.json` so the drawer, the import
// page and the composer can answer "is this one of them?" without opening the
// transcript.
//
// The transcript is what the first message in the imported session carries to
// the model (`takePreamble`), and what 查看记录 shows; once that preamble has
// gone out, `seeded` records it so a later message does not repeat it.
//
// A host session with no turn yet is *blank*, and the drawer hides blank rows —
// so an imported conversation is visible only because the drawer consults
// [importedTitlesProvider] (see SessionsController._visible): its id is here and
// its title is here, both without asking the host again.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'deepseek_export.dart';

/// One imported conversation.
class ImportedChat {
  const ImportedChat({
    required this.sessionId,
    required this.title,
    required this.messageCount,
    required this.importedAt,
    this.seeded = false,
    this.account,
    this.sourceId,
    this.sourceCreatedAt,
    this.sourceUpdatedAt,
  });

  final String sessionId;
  final String title;
  final int messageCount;
  final DateTime importedAt;

  /// The history has already been handed to the model once.
  final bool seeded;

  /// The masked DeepSeek account the export came from, when it said so.
  final String? account;

  /// The conversation's id inside the DeepSeek export. Importing the same export
  /// twice skips these, so a second run costs the conversations it adds only.
  final String? sourceId;

  /// When the conversation started and when it last moved, in DeepSeek. The host
  /// dates a session the moment it was created, which would put every imported
  /// conversation in 今天 and sort a year of chats as if it were one day.
  final DateTime? sourceCreatedAt;
  final DateTime? sourceUpdatedAt;

  /// What the drawer sorts and stamps this row with.
  DateTime get shownUpdatedAt => sourceUpdatedAt ?? sourceCreatedAt ?? importedAt;
  DateTime get shownCreatedAt => sourceCreatedAt ?? sourceUpdatedAt ?? importedAt;

  ImportedChat copyWith({bool? seeded, String? title, int? messageCount}) => ImportedChat(
    sessionId: sessionId,
    title: title ?? this.title,
    messageCount: messageCount ?? this.messageCount,
    importedAt: importedAt,
    seeded: seeded ?? this.seeded,
    account: account,
    sourceId: sourceId,
    sourceCreatedAt: sourceCreatedAt,
    sourceUpdatedAt: sourceUpdatedAt,
  );

  Map<String, Object?> toJson() => {
    'sessionId': sessionId,
    'title': title,
    'messageCount': messageCount,
    'importedAt': importedAt.toIso8601String(),
    'seeded': seeded,
    'account': account,
    if (sourceId != null) 'sourceId': sourceId,
    if (sourceCreatedAt != null) 'sourceCreatedAt': sourceCreatedAt!.toIso8601String(),
    if (sourceUpdatedAt != null) 'sourceUpdatedAt': sourceUpdatedAt!.toIso8601String(),
  };

  static ImportedChat? fromJson(Object? json) {
    if (json is! Map) return null;
    final sessionId = json['sessionId'];
    if (sessionId is! String || sessionId.isEmpty) return null;
    DateTime? time(Object? value) => value is String ? DateTime.tryParse(value) : null;
    return ImportedChat(
      sessionId: sessionId,
      title: json['title'] is String ? json['title'] as String : '',
      messageCount: json['messageCount'] is int ? json['messageCount'] as int : 0,
      importedAt: time(json['importedAt']) ?? DateTime.fromMillisecondsSinceEpoch(0),
      seeded: json['seeded'] == true,
      account: json['account'] is String ? json['account'] as String : null,
      sourceId: json['sourceId'] is String ? json['sourceId'] as String : null,
      sourceCreatedAt: time(json['sourceCreatedAt']),
      sourceUpdatedAt: time(json['sourceUpdatedAt']),
    );
  }
}

/// One conversation about to be recorded: what the importer hands over in a batch.
class ImportedChatDraft {
  const ImportedChatDraft({
    required this.sessionId,
    required this.title,
    required this.messages,
    this.sourceId,
    this.account,
    this.sourceCreatedAt,
    this.sourceUpdatedAt,
  });

  final String sessionId;
  final String title;
  final List<DeepSeekMessage> messages;
  final String? sourceId;
  final String? account;
  final DateTime? sourceCreatedAt;
  final DateTime? sourceUpdatedAt;
}

/// Where the imported transcripts live.
final importedChatsDirProvider = FutureProvider<Directory>((ref) async {
  final support = await getApplicationSupportDirectory();
  final dir = Directory('${support.path}/deepseek_import');
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
});

/// Every imported conversation, by the session it became.
///
/// The drawer reads this for the three things a blank host row can't answer by
/// itself: the row is one of ours (so it is shown at all), what it is called, and
/// when it really happened (the host dates it the moment it was created).
final importedIndexProvider = Provider<Map<String, ImportedChat>>((ref) {
  final chats = ref.watch(importedChatsProvider).value ?? const <ImportedChat>[];
  return {for (final chat in chats) chat.sessionId: chat};
});

/// Session id → the title its conversation had in DeepSeek.
final importedTitlesProvider = Provider<Map<String, String>>((ref) {
  final index = ref.watch(importedIndexProvider);
  return {for (final entry in index.entries) entry.key: entry.value.title};
});

final importedChatsProvider = AsyncNotifierProvider<ImportedChatsController, List<ImportedChat>>(
  ImportedChatsController.new,
);

class ImportedChatsController extends AsyncNotifier<List<ImportedChat>> {
  bool _backfilling = false;

  @override
  Future<List<ImportedChat>> build() async {
    final index = await _readIndex();
    final dir = await _dir();
    final known = <ImportedChat>[];
    for (final entry in index) {
      if (await File('${dir.path}/${entry.sessionId}.json').exists()) known.add(entry);
    }
    known.sort((a, b) => b.shownUpdatedAt.compareTo(a.shownUpdatedAt));
    // An index written before the times were recorded is repaired in the
    // background from the transcripts it already has (no re-import needed).
    unawaited(_backfillTimes(known));
    return known;
  }

  /// Fills [ImportedChat.sourceCreatedAt] / [ImportedChat.sourceUpdatedAt] for
  /// entries that were written without them, from the first and last message of
  /// the transcript on disk. Runs once per launch, off the drawer's path.
  Future<void> _backfillTimes(List<ImportedChat> chats) async {
    if (_backfilling) return;
    final stale = [
      for (final chat in chats)
        if (chat.sourceCreatedAt == null && chat.sourceUpdatedAt == null) chat,
    ];
    if (stale.isEmpty) return;
    _backfilling = true;
    try {
      final dir = await _dir();
      final patched = <String, ImportedChat>{};
      for (final chat in stale) {
        final times = <DateTime>[];
        try {
          final file = File('${dir.path}/${chat.sessionId}.json');
          if (!await file.exists()) continue;
          final json = jsonDecode(await file.readAsString());
          final raw = json is Map ? json['messages'] : null;
          if (raw is List) {
            for (final item in raw) {
              final at = _messageFromJson(item)?.at;
              if (at != null) times.add(at);
            }
          }
        } on Object {
          continue;
        }
        if (times.isEmpty) continue;
        times.sort();
        patched[chat.sessionId] = ImportedChat(
          sessionId: chat.sessionId,
          title: chat.title,
          messageCount: chat.messageCount,
          importedAt: chat.importedAt,
          seeded: chat.seeded,
          account: chat.account,
          sourceId: chat.sourceId,
          sourceCreatedAt: times.first,
          sourceUpdatedAt: times.last,
        );
      }
      if (patched.isEmpty) return;
      final next = [for (final chat in state.value ?? chats) patched[chat.sessionId] ?? chat]
        ..sort((a, b) => b.shownUpdatedAt.compareTo(a.shownUpdatedAt));
      state = AsyncValue.data(next);
      await _writeIndex(next);
    } on Object {
      // The times are cosmetic: a failure here leaves the rows dated as the host
      // has them, and the next launch tries again.
    } finally {
      _backfilling = false;
    }
  }

  Future<Directory> _dir() => ref.read(importedChatsDirProvider.future);

  Future<List<ImportedChat>> _readIndex() async {
    final file = File('${(await _dir()).path}/index.json');
    if (!await file.exists()) return const [];
    try {
      final json = jsonDecode(await file.readAsString());
      final chats = json is Map ? json['chats'] : null;
      if (chats is! List) return const [];
      return [for (final item in chats) ?ImportedChat.fromJson(item)];
    } on Object {
      return const [];
    }
  }

  Future<void> _writeIndex(List<ImportedChat> chats) async {
    final dir = await _dir();
    final file = File('${dir.path}/index.json');
    await file.writeAsString(
      jsonEncode({
        'version': 2,
        'chats': [for (final chat in chats) chat.toJson()],
      }),
      flush: true,
    );
  }

  /// 以前导入过的对话:用这次导出里的时间、条数和标题把索引补齐 ——
  /// 不新建会话,也不动本机记录,只修「创建/最后一条」那两个时间。
  Future<int> refreshFromExport(Iterable<DeepSeekChat> chats) async {
    final bySource = {
      for (final chat in chats)
        if (chat.id.isNotEmpty) chat.id: chat,
    };
    if (bySource.isEmpty) return 0;
    final current = state.value ?? await future;
    var patched = 0;
    final next = <ImportedChat>[];
    for (final entry in current) {
      final chat = entry.sourceId == null ? null : bySource[entry.sourceId!];
      if (chat == null) {
        next.add(entry);
        continue;
      }
      patched++;
      next.add(
        ImportedChat(
          sessionId: entry.sessionId,
          title: chat.sessionTitle.isEmpty ? entry.title : chat.sessionTitle,
          messageCount: chat.messages.length,
          importedAt: entry.importedAt,
          seeded: entry.seeded,
          account: entry.account,
          sourceId: entry.sourceId,
          sourceCreatedAt: chat.createdAt ?? entry.sourceCreatedAt,
          sourceUpdatedAt: chat.updatedAt ?? entry.sourceUpdatedAt,
        ),
      );
    }
    if (patched > 0) {
      state = AsyncValue.data(next);
      await _writeIndex(next);
    }
    return patched;
  }

  /// The DeepSeek conversation ids already imported, plus their titles (an
  /// index written before [ImportedChat.sourceId] existed has only the title,
  /// and a re-import of the same export must not double it).
  Future<({Set<String> ids, Set<String> titles})> alreadyImported() async {
    final chats = state.value ?? await future;
    return (
      ids: {
        for (final chat in chats)
          if (chat.sourceId != null) chat.sourceId!,
      },
      titles: {for (final chat in chats) chat.title},
    );
  }

  /// Records one chunk of a running import: every transcript, then one index
  /// write and one state update for the whole chunk.
  ///
  /// The import page shows the list as it grows and the drawer picks the rows up
  /// from [importedTitlesProvider], so a chunk of a few dozen keeps both cheap;
  /// writing the index per conversation would make a five-hundred-conversation
  /// import a quadratic amount of JSON.
  Future<void> recordAll(List<ImportedChatDraft> drafts) async {
    if (drafts.isEmpty) return;
    final dir = await _dir();
    final now = DateTime.now();
    final entries = <ImportedChat>[];
    for (final draft in drafts) {
      await File('${dir.path}/${draft.sessionId}.json').writeAsString(
        jsonEncode({
          'version': 1,
          'title': draft.title,
          'messages': [for (final message in draft.messages) _messageToJson(message)],
        }),
        flush: true,
      );
      entries.add(
        ImportedChat(
          sessionId: draft.sessionId,
          title: draft.title,
          messageCount: draft.messages.length,
          importedAt: now,
          account: draft.account,
          sourceId: draft.sourceId,
          sourceCreatedAt: draft.sourceCreatedAt,
          sourceUpdatedAt: draft.sourceUpdatedAt,
        ),
      );
    }
    final next = [...?state.value, ...entries]..sort((a, b) => b.shownUpdatedAt.compareTo(a.shownUpdatedAt));
    state = AsyncValue.data(next);
    await _writeIndex(next);
  }

  /// The title the transcript file itself carries: proof of which conversation
  /// a file on disk belongs to, when two of them look the same on screen.
  Future<String?> storedTitle(String sessionId) async {
    final file = File('${(await _dir()).path}/$sessionId.json');
    if (!await file.exists()) return null;
    try {
      final json = jsonDecode(await file.readAsString());
      return json is Map ? json['title'] as String? : null;
    } on Object {
      return null;
    }
  }

  Future<List<DeepSeekMessage>?> transcript(String sessionId) async {
    final file = File('${(await _dir()).path}/$sessionId.json');
    if (!await file.exists()) return null;
    try {
      final json = jsonDecode(await file.readAsString());
      final raw = json is Map ? json['messages'] : null;
      if (raw is! List) return null;
      return [for (final item in raw) ?_messageFromJson(item)];
    } on Object {
      return null;
    }
  }

  /// The history to carry into the model, once per session. Null when this
  /// session was not imported, or when it has been carried already.
  Future<String?> takePreamble(String sessionId, {int maxChars = 6000}) async {
    final chats = state.value ?? await future;
    final index = chats.indexWhere((chat) => chat.sessionId == sessionId);
    if (index < 0 || chats[index].seeded) return null;
    final messages = await transcript(sessionId);
    if (messages == null || messages.isEmpty) return null;
    final preamble = DeepSeekChat(
      id: sessionId,
      title: chats[index].title,
      messages: messages,
    ).contextPreamble(maxChars: maxChars);
    if (preamble.isEmpty) return null;
    final next = [...chats];
    next[index] = chats[index].copyWith(seeded: true);
    state = AsyncValue.data(next);
    await _writeIndex(next);
    return preamble;
  }

  Future<ImportedChat?> entryFor(String sessionId) async {
    final chats = state.value ?? await future;
    for (final chat in chats) {
      if (chat.sessionId == sessionId) return chat;
    }
    return null;
  }

  Future<void> forget(String sessionId) async {
    final chats = state.value ?? await future;
    final next = chats.where((chat) => chat.sessionId != sessionId).toList();
    state = AsyncValue.data(next);
    await _writeIndex(next);
    final file = File('${(await _dir()).path}/$sessionId.json');
    if (await file.exists()) await file.delete();
  }

  static Map<String, Object?> _messageToJson(DeepSeekMessage message) => {
    'role': message.role.name,
    'text': message.text,
    if (message.thinking.isNotEmpty) 'thinking': message.thinking,
    if (message.at != null) 'at': message.at!.toIso8601String(),
    if (message.stopped) 'stopped': true,
    if (message.searchQueries.isNotEmpty) 'queries': message.searchQueries,
    if (message.sources.isNotEmpty)
      'sources': [
        for (final source in message.sources) {'title': source.title, 'url': source.url, 'site': source.site},
      ],
    if (message.attachments.isNotEmpty)
      'attachments': [
        for (final file in message.attachments) {'name': file.name, 'bytes': file.bytes, 'isImage': file.isImage},
      ],
  };

  static DeepSeekMessage? _messageFromJson(Object? json) {
    if (json is! Map) return null;
    final role = json['role'] == 'assistant' ? DeepSeekRole.assistant : DeepSeekRole.user;
    final sources = json['sources'];
    final attachments = json['attachments'];
    final queries = json['queries'];
    return DeepSeekMessage(
      role: role,
      text: json['text'] is String ? json['text'] as String : '',
      thinking: json['thinking'] is String ? json['thinking'] as String : '',
      at: DateTime.tryParse(json['at'] is String ? json['at'] as String : ''),
      stopped: json['stopped'] == true,
      searchQueries: [
        if (queries is List)
          for (final query in queries)
            if (query is String) query,
      ],
      sources: [
        if (sources is List)
          for (final source in sources)
            if (source is Map)
              DeepSeekSource(
                title: source['title'] is String ? source['title'] as String : '',
                url: source['url'] is String ? source['url'] as String : '',
                site: source['site'] is String ? source['site'] as String : '',
              ),
      ],
      attachments: [
        if (attachments is List)
          for (final file in attachments)
            if (file is Map)
              DeepSeekAttachment(
                name: file['name'] is String ? file['name'] as String : '',
                bytes: file['bytes'] is int ? file['bytes'] as int : 0,
                isImage: file['isImage'] == true,
              ),
      ],
    );
  }
}
