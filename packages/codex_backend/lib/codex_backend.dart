/// Codex adapter for the existing chat API and Flutter presentation models.
/// No DSH engine is started, and unsupported DSH APIs fail closed.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:codex_client/host_files.dart';

import 'package:codex_client/codex_client.dart';
import 'package:dsh_client/dsh_client.dart';

part 'phase_two.dart';

Map<String, dynamic> obj(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : {};
List<Map<String, dynamic>> rows(Object? v) =>
    v is List ? v.map(obj).toList() : [];
const unsupported = DshRemoteException(
  'METHOD_NOT_ALLOWED',
  '此功能尚未适配 Codex 后端',
);

class CodexChatClient extends DshClient {
  CodexChatClient(
    this.codex, {
    this.home = '/home',
    this.cwd,
    this.files,
    Map<String, Future<String>>? submissionLedger,
  }) : _submitted = submissionLedger ?? {},
       super.withCarrier(
         _LifecycleCarrier(codex, home),
         muxOptions: const MuxOptions(autoReconnect: false),
       ) {
    (carrier as _LifecycleCarrier).fileCall = files == null ? null : _fileCall;
    _sub = codex.messages.listen(_receive);
    codex.done.then((_) {
      _closed = true;
      for (final v in _views.values) {
        v.timer?.cancel();
      }
      for (final id in _requests.keys.toList()) {
        _host(HostRequestCancelledEvent(id));
      }
      _requests.clear();
    });
  }
  final CodexRpc codex;
  final CodexHostFiles? files;
  final _receipts = <String, ({String sessionId, String path})>{};
  final _usage = <String, Map<String, Object?>>{};
  int _usageSeq = 0;
  final String home;
  final String? cwd;
  late final StreamSubscription<Map<String, dynamic>> _sub;
  final _hostEvents = StreamController<HostEvent>.broadcast();
  final _workspaceEvents = StreamController<WorkspaceUpdate>.broadcast();
  final _controlEvents = StreamController<SessionControlUpdate>.broadcast();
  final _views = <String, _View>{};
  // Threads created on this connection have no persisted history until a turn starts.
  final _freshThreads = <String>{};
  final _threads = <String, Map<String, dynamic>>{};
  final _requests = <String, Map<String, dynamic>>{};
  final _sending = <String>{};
  final Map<String, Future<String>> _submitted;
  final _models = <String, ModelSelection>{};
  final _effectiveModels = <String, ModelSelection>{};
  final _archived = <String>{};
  int _requestEpoch = 0;
  bool _closed = false;
  bool _checkingAccount = false;
  String? _accountIdentity;
  @override
  String? get accountIdentity => _accountIdentity;
  Future<List<SessionSummary>>? _listing;
  @override
  ChatCapabilities get capabilities => const ChatCapabilities(
    backend: 'codex',
    advanced: false,
    supportsQuietWatch: false,
    attachments: true,
  );
  @override
  Stream<HostEvent> get hostEvents => _hostEvents.stream;
  void _host(HostEvent event) {
    if (!_hostEvents.isClosed) _hostEvents.add(event);
  }

  Future<void> ready() async {
    final account = await _call('account/read', {'refreshToken': false});
    _accountIdentity = _identity(account);
    await mux.ready();
  }

  String _identity(Map<String, dynamic> r) {
    final a = obj(r['account']);
    return jsonEncode([
      a['type'],
      a['email'],
      a['accountId'],
      a['organizationId'],
    ]);
  }

  Future<void> _checkAccount() async {
    if (_checkingAccount || _closed) return;
    _checkingAccount = true;
    try {
      final next = _identity(
        await _call('account/read', {'refreshToken': false}),
      );
      if (_accountIdentity != null && next != _accountIdentity) {
        _host(const CredentialUpdatedEvent('codex-account'));
        await close();
      }
    } catch (_) {
      /* transport lifecycle handles disconnects */
    } finally {
      _checkingAccount = false;
    }
  }

  Future<Map<String, dynamic>> _call(
    String method,
    Map<String, dynamic> args,
  ) async {
    try {
      return await codex.request(method, args);
    } on CodexRpcException catch (e) {
      throw DshRemoteException('codex/${e.code}', e.message);
    } catch (e) {
      throw DshTransportException('Codex 连接中断或响应超时，请刷新后核对结果', e);
    }
  }

  SessionProjections _projection(Map<String, dynamic> t) {
    final model =
        _models[t['id']] ??
        _effectiveModels[t['id']] ??
        ModelSelection(
          provider: 'codex',
          model: t['model']?.toString() ?? '',
          reasoningEffort: t['reasoningEffort'] as String?,
        );
    return SessionProjections(_usageSeq, {
      ...?_usage[t['id']],
      'title': t['name'] ?? t['preview'] ?? 'Codex',
      'modelSelection': {'next': model.toJson(), 'lastUsed': model.toJson()},
      'inbox': {'next-turn': [], 'next-step': []},
    });
  }

  bool _running(Map<String, dynamic> t) => obj(t['status'])['type'] == 'active';
  SessionSummary _summary(Map<String, dynamic> t) => SessionSummary(
    sessionId: t['id'] as String,
    updatedAt: DateTime.fromMillisecondsSinceEpoch(
      ((t['updatedAt'] as num?) ?? 0).toInt() * 1000,
    ),
    running: _running(t),
    blank: false,
    agentAvailable: true,
    cwd: t['cwd'] as String?,
    parentSessionId: t['parentThreadId'] as String?,
    origin: t['parentThreadId'] == null ? null : 'subagent',
    projections: _projection(t),
    projectionsKind: 'sequenced',
  );

  @override
  Future<List<SessionSummary>> listSessions() =>
      _listing ??= _list().whenComplete(() => _listing = null);
  Future<List<SessionSummary>> _list() async {
    final found = <String, Map<String, dynamic>>{};
    final archived = <String>{};
    for (final isArchived in [false, true]) {
      String? cursor;
      final seen = <String>{};
      do {
        final page = await _call('thread/list', {
          'limit': 100,
          'useStateDbOnly': true,
          'archived': isArchived,
          'sortKey': 'updated_at',
          if (cursor != null) 'cursor': cursor,
        });
        for (final t in rows(page['data'])) {
          found[t['id'] as String] = t;
          if (isArchived) archived.add(t['id'] as String);
        }
        cursor = page['nextCursor'] as String?;
        if (cursor != null && !seen.add(cursor))
          throw const DshProtocolException('Codex repeated list cursor');
      } while (cursor != null);
    }
    if (_closed) return [];
    for (final id in _freshThreads) {
      if (!_archived.contains(id) && _threads[id] != null)
        found.putIfAbsent(id, () => _threads[id]!);
    }
    _threads.addAll(found);
    _archived
      ..clear()
      ..addAll(archived);
    _workspaceEvents.add(WorkspaceArchivedUpdate(_archived.toList()));
    return found.values.map(_summary).toList();
  }

  @override
  Future<SessionCreated> createSession({
    String? cwd,
    String? workspaceId,
    String? agentPreset,
    String? sessionId,
  }) async {
    if (workspaceId != null || agentPreset != null) throw unsupported;
    final r = await _call(
      sessionId == null ? 'thread/start' : 'thread/resume',
      {
        if (sessionId != null) 'threadId': sessionId,
        if (cwd ?? this.cwd case final path?) 'cwd': path,
      },
    );
    final t = obj(r['thread']);
    _rememberModel(t['id'] as String, r);
    final id = t['id'] as String;
    _threads[id] = t;
    if (sessionId == null) {
      // thread/start already joins the thread and returns its initial state.
      // Resuming it before the first turn fails because no rollout exists yet.
      final view = _views.putIfAbsent(id, () => _View(id));
      view.thread = t;
      view.loaded = true;
      view.mergePage(rows(t['turns']).reversed.toList(), older: false);
      _freshThreads.add(id);
    }
    _host(SessionAddedEvent(_summary(t)));
    return SessionCreated(t['id'] as String, null);
  }

  @override
  Future<SessionProjections?> projections(String sessionId) async {
    final t = obj(
      (await _call('thread/read', {
        'threadId': sessionId,
        'includeTurns': false,
      }))['thread'],
    );
    _threads[sessionId] = t;
    await _seedUsage(sessionId, t);
    return _projection(t);
  }

  @override
  Future<String> renameSession(String sessionId, String title) async {
    await _call('thread/name/set', {'threadId': sessionId, 'name': title});
    if (_threads[sessionId] case final t?) {
      t['name'] = title;
      _host(SessionAddedEvent(_summary(t)));
    }
    return title;
  }

  @override
  Future<List<String>> archiveSession(
    String sessionId, {
    bool? stopActivity,
  }) async {
    final t = obj(
      (await _call('thread/read', {
        'threadId': sessionId,
        'includeTurns': false,
      }))['thread'],
    );
    if (_running(t))
      throw const DshRemoteException('codex/busy', '请先停止当前任务，再归档对话');
    await _call('thread/archive', {'threadId': sessionId});
    _freshThreads.remove(sessionId);
    _archived.add(sessionId);
    _workspaceEvents.add(WorkspaceArchivedUpdate(_archived.toList()));
    return _archived.toList();
  }

  @override
  Future<List<String>> unarchiveSession(String sessionId) async {
    await _call('thread/unarchive', {'threadId': sessionId});
    _archived.remove(sessionId);
    _workspaceEvents.add(WorkspaceArchivedUpdate(_archived.toList()));
    return _archived.toList();
  }

  @override
  Stream<WorkspaceUpdate> watchWorkspaces() async* {
    yield WorkspaceBaseline(const [], _archived.toList(), const []);
    yield* _workspaceEvents.stream;
  }

  @override
  Stream<SessionControlUpdate> watchSessionControl() async* {
    yield SessionControlBaseline({
      for (final t in _threads.values) t['id'] as String: _projection(t),
    });
    yield* _controlEvents.stream;
  }

  Future<_View> _load(String id) async {
    final v = _views.putIfAbsent(id, () => _View(id));
    if (_freshThreads.contains(id)) return v;
    await (v.loading ??= _hydrate(v).whenComplete(() => v.loading = null));
    return v;
  }

  void _rememberModel(String id, Map<String, dynamic> response) {
    if (response['model'] is String) {
      _effectiveModels[id] = ModelSelection(
        provider: 'codex',
        model: response['model'] as String,
        reasoningEffort: response['reasoningEffort'] as String?,
      );
    }
  }

  Future<void> _hydrate(_View v) async {
    v.hydrating = true;
    try {
      final r = await _call('thread/resume', {
        'threadId': v.id,
        'excludeTurns': true,
      });
      v.thread = obj(r['thread']);
      _rememberModel(v.id, r);
      _threads[v.id] = v.thread;
      final page = await _call('thread/turns/list', {
        'threadId': v.id,
        'limit': 10,
        'sortDirection': 'desc',
        'itemsView': 'full',
      });
      v.mergePage(rows(page['data']), older: false);
      v.cursor = page['nextCursor'] as String?;
      v.loaded = true;
    } finally {
      v.hydrating = false;
    }
    final pending = List<Map<String, dynamic>>.of(v.buffer);
    v.buffer.clear();
    for (final m in pending) {
      // The fetched page already includes streamed prefixes. Never append
      // buffered deltas a second time; complete items replace their prefix.
      final method = m['method']?.toString() ?? '';
      final p = obj(m['params']);
      if (method == 'item/started' &&
          rows(v.turns[p['turnId']]?['items'])
              .any((i) => i['id'] == obj(p['item'])['id']))
        continue;
      if (method == 'turn/started' && v.turns.containsKey(obj(p['turn'])['id']))
        continue;
      if (!method.endsWith('/delta') && !method.endsWith('/outputDelta'))
        _receive(m);
    }
  }

  @override
  Stream<DshEvent> watch(
    String sessionId, {
    WatchOptions options = const WatchOptions(),
  }) {
    late StreamController<DshEvent> out;
    StreamSubscription<void>? changes;
    StreamSubscription<HostEvent>? hosts;
    SessionFollowEpoch? epoch;
    bool cancelled = false;
    Future<void> start() async {
      try {
        final generation = await mux.ready();
        epoch = SessionFollowEpoch(generation: generation);
        out.add(SessionSyncEvent(epoch!));
        final v = await _load(sessionId);
        if (cancelled) return;
        void publish() {
          if (cancelled || _closed) return;
          out.add(v.snapshot(_projection(v.thread), epoch!));
          out.add(SessionStatusEvent(sessionId, v.running));
        }

        changes = v.changes.stream.listen((_) => publish());
        hosts = hostEvents.listen((e) {
          final matches = switch (e) {
            ApprovalRequestedEvent(:final request) =>
              request.sessionId == sessionId,
            UserQuestionRequestedEvent(:final request) =>
              request.sessionId == sessionId,
            SessionStatusEvent(:final sessionId) ||
            SessionErrorEvent(:final sessionId) => sessionId == v.id,
            HostRequestCancelledEvent() => true,
            _ => false,
          };
          if (matches && !cancelled) out.add(e);
        });
        publish();
        for (final request in _requests.entries) {
          if (obj(request.value['params'])['threadId'] == sessionId) {
            final e = _requestEvent(request.key, request.value);
            if (e != null) out.add(e);
          }
        }
      } catch (e, st) {
        if (!cancelled) out.addError(e, st);
      }
    }

    out = StreamController<DshEvent>(
      onListen: () {
        unawaited(start());
      },
      onCancel: () async {
        cancelled = true;
        epoch?.retire();
        await changes?.cancel();
        await hosts?.cancel();
      },
    );
    return out.stream;
  }

  @override
  Future<HistoryPage> history(
    String sessionId, {
    required int throughSeq,
    int? beforeSeq,
    int? maxMessages,
    TurnWindow? turnWindow,
  }) async {
    final v = _views[sessionId];
    if (v == null || v.cursor == null) return const HistoryPage([], false);
    final page = await _call('thread/turns/list', {
      'threadId': sessionId,
      'limit': 10,
      'sortDirection': 'desc',
      'itemsView': 'full',
      'cursor': v.cursor,
    });
    v.mergePage(rows(page['data']), older: true);
    v.cursor = page['nextCursor'] as String?;
    return HistoryPage(
      v.events().where((e) => beforeSeq == null || e.seq < beforeSeq).toList(),
      v.cursor != null,
    );
  }

  @override
  Future<String> prompt(
    String sessionId,
    String text, {
    List<PromptImage> images = const [],
    List<String> fileReceiptIds = const [],
    String? requestId,
    PromptMode mode = PromptMode.queue,
    String? timeZone,
  }) {
    final key =
        '$_accountIdentity:$sessionId:${requestId ?? DateTime.now().microsecondsSinceEpoch}';
    // Keep unknown outcomes; retries with the same request ID never send twice.
    return _submitted.putIfAbsent(
      key,
      () => _send(
        sessionId,
        text,
        requestId ?? key,
        mode,
        images,
        fileReceiptIds,
      ),
    );
  }

  Future<String> _send(
    String id,
    String text,
    String requestId,
    PromptMode mode,
    List<PromptImage> images,
    List<String> receipts,
  ) async {
    if (!_sending.add(id))
      throw const DshRemoteException('codex/busy', '上一条消息仍在发送，请稍后再试');
    try {
      final v = _views[id] ?? await _load(id);
      final turn = v.activeTurn;
      if (turn != null && mode == PromptMode.queue)
        throw const DshRemoteException(
          'METHOD_NOT_ALLOWED',
          '当前版本不支持 Codex 排队，请使用插话',
        );
      final input = <Map<String, dynamic>>[];
      for (final receipt in receipts) {
        final file = _receipts[receipt];
        if (file == null || file.sessionId != id) throw unsupported;
        final name = file.path
            .split('/')
            .last
            .replaceAll(RegExp(r'[\]<>\n]'), '_');
        text += '\n\n[附件：$name](<${file.path}>)';
      }
      if (text.isNotEmpty)
        input.add({'type': 'text', 'text': text, 'text_elements': []});
      for (final image in images) {
        if (files == null) throw unsupported;
        final bytes = base64Decode(image.base64Data);
        if (bytes.length > 20 * 1024 * 1024)
          throw const DshRemoteException('attachment/too-large', '图片超过 20 MiB');
        final path = await files!.upload(
          image.name ?? 'image.${image.mediaType.split('/').last}',
          bytes,
        );
        input.add({'type': 'localImage', 'path': path});
      }
      final model = _models[id];
      v.echoes[requestId] = requestId;
      final r = await _call(turn == null ? 'turn/start' : 'turn/steer', {
        'threadId': id,
        'clientUserMessageId': requestId,
        'input': input,
        if (turn != null) 'expectedTurnId': turn,
        if (turn == null && model != null) ...{
          'model': model.model,
          if (model.reasoningEffort != null) 'effort': model.reasoningEffort,
        },
      });
      if (r['turn'] is Map) v.upsertTurn(obj(r['turn']));
      _freshThreads.remove(id);
      v.echoes[requestId] = requestId;
      v.changed();
      return requestId;
    } finally {
      _sending.remove(id);
    }
  }

  @override
  bool supportsEndpoint(String endpoint) =>
      (files != null &&
          {
            'fileUploads/upload',
            'workspaceFiles/stat',
            'workspaceFiles/read',
            'workspaceFiles/readBytes',
            'session/search',
          }.contains(endpoint)) ||
      super.supportsEndpoint(endpoint);

  @override
  Future<FileReceipt> uploadFile(
    String sessionId,
    List<int> bytes, {
    String? name,
  }) async {
    if (files == null) throw unsupported;
    final path = await files!.upload(name ?? 'file', Uint8List.fromList(bytes));
    _receipts[path] = (sessionId: sessionId, path: path);
    return FileReceipt(
      path,
      FileAttachment(
        attachmentId: path,
        name: name ?? 'file',
        bytes: bytes.length,
      ),
    );
  }

  @override
  Future<({ImageAttachment attachment, Uint8List bytes})> attachment(
    String sessionId,
    String attachmentId,
  ) async {
    final v = _views[sessionId] ?? await _load(sessionId);
    for (final turn in v.turns.values) {
      for (final item in rows(turn['items'])) {
        if (item['type'] == 'imageGeneration' &&
            attachmentId == 'codex-generated:${item['id']}') {
          final Uint8List bytes;
          if (item['savedPath'] is String) {
            bytes = await readFileBytes(
              sessionId,
              item['savedPath'] as String,
              maxBytes: 20 * 1024 * 1024,
            );
          } else if (item['result'] is String &&
              (item['result'] as String).length <= 28 * 1024 * 1024) {
            bytes = base64Decode(item['result'] as String);
          } else {
            throw unsupported;
          }
          return (
            attachment: ImageAttachment(
              attachmentId: attachmentId,
              mediaType: 'image/png',
              bytes: bytes.length,
            ),
            bytes: bytes,
          );
        }
        final tool = item['type'] != 'userMessage';
        final content = item['type'] == 'imageView'
            ? <Map<String, dynamic>>[
                {'type': 'localImage', 'path': item['path']},
              ]
            : item['type'] == 'dynamicToolCall'
            ? rows(item['contentItems'])
                  .map(
                    (c) => c['type'] == 'inputImage'
                        ? <String, dynamic>{
                            'type': 'image',
                            'url': c['imageUrl'],
                          }
                        : c,
                  )
                  .toList()
            : rows(item['content']);
        for (var i = 0; i < content.length; i++) {
          if (attachmentId !=
              '${tool ? 'codex-tool' : 'codex-image'}:${item['id']}:$i')
            continue;
          final c = content[i];
          Uint8List bytes;
          if (c['type'] == 'localImage') {
            bytes = await readFileBytes(
              sessionId,
              c['path'] as String,
              maxBytes: 20 * 1024 * 1024,
            );
          } else if (c['type'] == 'image' &&
              c['url'] is String &&
              (c['url'] as String).startsWith('data:image/')) {
            final url = c['url'] as String;
            if (url.length > 28 * 1024 * 1024) throw unsupported;
            bytes = UriData.parse(url).contentAsBytes();
          } else {
            throw unsupported;
          }
          return (
            attachment: ImageAttachment(
              attachmentId: attachmentId,
              mediaType: _imageMime(c['path'] ?? c['url'] ?? ''),
              bytes: bytes.length,
            ),
            bytes: bytes,
          );
        }
      }
    }
    throw const DshRemoteException('workspace-file/not-found', '找不到图片');
  }

  @override
  Future<({List<({String sessionId, String snippet})> items, bool hasMore})>
  searchSessionsPage(String query) async {
    if (files == null) throw unsupported;
    if (query.trim().isEmpty || query.length > 500)
      return (items: <({String sessionId, String snippet})>[], hasMore: false);
    final listed = (await listSessions()).map((s) => s.sessionId).toSet();
    final threads =
        _threads.values
            .where((t) => listed.contains(t['id']) && t['path'] is String)
            .toList()
          ..sort(
            (a, b) => ((b['updatedAt'] as num?) ?? 0).compareTo(
              (a['updatedAt'] as num?) ?? 0,
            ),
          );
    final r = await files!.inspect({
      'query': query,
      'threads': [
        for (final t in threads) {'id': t['id'], 'path': t['path']},
      ],
    });
    return (
      items: [
        for (final hit in rows(r['items']))
          (
            sessionId: hit['sessionId'] as String,
            snippet: hit['snippet'] as String,
          ),
      ],
      hasMore: r['hasMore'] == true,
    );
  }

  @override
  Future<Map<String, Object?>> accountUsage() async =>
      await _call('account/rateLimits/read', {});

  @override
  Future<void> cancel(String sessionId) async {
    final v = _views[sessionId];
    if (v?.activeTurn case final turn?)
      await _call('turn/interrupt', {'threadId': sessionId, 'turnId': turn});
  }

  @override
  Future<ModelCatalog> listModels() async {
    final all = <ModelInfo>[];
    ModelSelection? selected;
    String? cursor;
    do {
      final r = await _call('model/list', {
        'limit': 100,
        if (cursor != null) 'cursor': cursor,
      });
      for (final m in rows(r['data'])) {
        if (m['hidden'] == true) continue;
        final id = (m['model'] ?? m['id']) as String;
        all.add(
          ModelInfo(
            provider: 'codex',
            id: id,
            name: m['displayName']?.toString() ?? id,
            description: m['description'] as String?,
            defaultEffort: m['defaultReasoningEffort'] as String?,
            efforts: rows(m['supportedReasoningEfforts'])
                .map(
                  (e) => ReasoningEffort(
                    e['reasoningEffort'] as String,
                    e['reasoningEffort'] as String,
                    e['description'] as String?,
                  ),
                )
                .toList(),
          ),
        );
        if (m['isDefault'] == true)
          selected = ModelSelection(
            provider: 'codex',
            model: id,
            reasoningEffort: m['defaultReasoningEffort'] as String?,
          );
      }
      cursor = r['nextCursor'] as String?;
    } while (cursor != null);
    return ModelCatalog(
      defaultSelection: selected,
      routableProviders: ['codex'],
      groups: [ProviderGroup('codex', 'Codex', all)],
      failures: const [],
    );
  }

  @override
  Future<ModelSelection> setModel(
    String sessionId, {
    required String provider,
    required String model,
    String? reasoningEffort,
  }) async {
    final catalog = await listModels();
    final matches = catalog.groups
        .expand((g) => g.models)
        .where((m) => m.id == model && m.provider == provider);
    if (matches.isEmpty ||
        reasoningEffort != null &&
            !matches.first.efforts.any((e) => e.id == reasoningEffort))
      throw const DshRemoteException('codex/model', '服务器不支持此模型或思考档位');
    final selected = ModelSelection(
      provider: provider,
      model: model,
      reasoningEffort: reasoningEffort,
    );
    _models[sessionId] = selected;
    _views[sessionId]?.changed();
    return selected;
  }

  @override
  Future<List<({String id, String name})>> listProviders() async => [
    (id: 'codex', name: 'Codex'),
  ];

  HostEvent? _requestEvent(String key, Map<String, dynamic> m) {
    final p = obj(m['params']);
    final id = p['threadId']?.toString();
    if (id == null) return null;
    if (m['method'] == 'item/tool/requestUserInput')
      return UserQuestionRequestedEvent(
        UserQuestionRequest(
          eventId: key,
          sessionId: id,
          waitCallId: p['itemId'] as String?,
          questions: rows(p['questions'])
              .map((q) => UserQuestion.fromJson(q))
              .toList(),
          raw: p,
        ),
      );
    if ([
      'item/commandExecution/requestApproval',
      'item/fileChange/requestApproval',
    ].contains(m['method'])) {
      final description = [
        p['reason'],
        p['command'],
        if (p['cwd'] != null) '目录: ${p['cwd']}',
      ].whereType<String>().join('\n');
      return ApprovalRequestedEvent(
        ApprovalRequest(
          eventId: key,
          sessionId: id,
          callId: p['itemId'] as String?,
          toolName: m['method'] == 'item/fileChange/requestApproval'
              ? 'fileChange'
              : 'commandExecution',
          reason: description.isEmpty ? '确认此工具操作' : description,
          raw: p,
        ),
      );
    }
    return null;
  }

  void _answer(String key, Map<String, dynamic> result) {
    final req = _requests[key];
    if (req == null || _closed)
      throw const DshRemoteException('codex/stale', '请求已处理或连接已失效，请刷新');
    codex.respond(req['id'] as Object, result: result);
    _requests.remove(key);
    _host(HostRequestCancelledEvent(key));
  }

  @override
  Future<void> respondApproval(
    ApprovalRequest request,
    ApprovalDecision decision,
  ) async {
    if (decision == ApprovalDecision.pass) throw unsupported;
    _answer(request.eventId, {
      'decision': decision == ApprovalDecision.allowOnce ? 'accept' : 'decline',
    });
  }

  @override
  Future<void> answerQuestion(
    UserQuestionRequest request,
    List<QuestionAnswer> answers,
  ) async => _answer(request.eventId, {
    'answers': {
      for (final a in answers)
        a.id: {
          'answers': [
            if (a.custom?.isNotEmpty == true) a.custom else ...a.selected,
          ],
        },
    },
  });
  @override
  Future<void> rejectQuestion(
    UserQuestionRequest request, {
    String name = 'UserQuestionError',
    String message = 'declined',
    String? code,
  }) async => _answer(request.eventId, {'answers': {}});

  void _receive(Map<String, dynamic> m) {
    if (_closed) return;
    final method = m['method'] as String? ?? '';
    final p = obj(m['params']);
    final id = p['threadId']?.toString() ?? obj(p['thread'])['id']?.toString();
    if (m.containsKey('id')) {
      // Only requests for threads explicitly joined by this connection are ours.
      if (id == null || !_views.containsKey(id)) return;
      final key = 'codex-${identityHashCode(this)}-${++_requestEpoch}';
      final event = _requestEvent(key, m);
      if (event != null) {
        _requests[key] = m;
        _host(event);
      } else {
        // Let a capable desktop client execute its own tools; never race it
        // with an automatic rejection from a mobile observer.
        _host(SessionErrorEvent(id, '此操作需要尚未适配的工具，请在支持它的客户端继续'));
      }
      return;
    }
    if (method == 'serverRequest/resolved') {
      for (final e in _requests.entries.toList()) {
        if (e.value['id'] == p['requestId']) {
          _requests.remove(e.key);
          _host(HostRequestCancelledEvent(e.key));
        }
      }
      return;
    }
    if (method == 'account/updated') {
      unawaited(_checkAccount());
      return;
    }
    if (id == null) return;
    if (method == 'thread/tokenUsage/updated') {
      _setUsage(id, obj(p['tokenUsage']));
      return;
    }
    final v = _views[id];
    if (v?.hydrating == true) {
      v!.buffer.add(m);
      return;
    }
    if (p['thread'] is Map) {
      _threads[id] = obj(p['thread']);
      if (v != null) v.thread = _threads[id]!;
    }
    if (method == 'thread/name/updated') {
      _threads[id]?['name'] = p['threadName'] ?? p['name'];
    }
    if (method == 'thread/archived') {
      _archived.add(id);
      _workspaceEvents.add(WorkspaceArchivedUpdate(_archived.toList()));
    }
    if (method == 'thread/unarchived') {
      _archived.remove(id);
      _workspaceEvents.add(WorkspaceArchivedUpdate(_archived.toList()));
    }
    if (method == 'thread/status/changed') {
      _threads[id]?['status'] = p['status'];
    }
    if (method == 'turn/started' || method == 'turn/completed') {
      final turn = obj(p['turn']);
      _freshThreads.remove(id);
      v?.upsertTurn(turn);
      _threads[id]?['status'] = {
        'type': method == 'turn/started' ? 'active' : 'idle',
      };
      _host(SessionStatusEvent(id, method == 'turn/started'));
    }
    if (v != null) {
      if (method == 'item/started' || method == 'item/completed')
        v.upsertItem(
          p['turnId'] as String,
          obj(p['item']),
          complete: method == 'item/completed',
        );
      if (method.endsWith('/delta') || method.endsWith('/outputDelta'))
        v.delta(p, method);
      if (method == 'error')
        _host(
          SessionErrorEvent(
            id,
            obj(p['error'])['message']?.toString() ?? 'Codex 运行失败',
          ),
        );
      v.changed();
    }
    if (_threads[id] case final thread?) {
      if (!method.contains('/delta') && !method.contains('/outputDelta'))
        _host(SessionAddedEvent(_summary(thread)));
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    await _sub.cancel();
    for (final v in _views.values) {
      v.timer?.cancel();
      unawaited(v.changes.close());
    }
    for (final key in _requests.keys) {
      _host(HostRequestCancelledEvent(key));
    }
    _requests.clear();
    await super.close();
    unawaited(_hostEvents.close());
    unawaited(_workspaceEvents.close());
    unawaited(_controlEvents.close());
  }
}

class _View {
  _View(this.id);
  final String id;
  Map<String, dynamic> thread = {};
  final turns = <String, Map<String, dynamic>>{};
  final ordinals = <String, int>{};
  final echoes = <String, String>{};
  final buffer = <Map<String, dynamic>>[];
  final changes = StreamController<void>.broadcast();
  Future<void>? loading;
  Timer? timer;
  String? cursor;
  bool loaded = false, hydrating = false;
  int minOrdinal = 100000, maxOrdinal = 100000;
  String? get activeTurn => turns.values
      .where((t) => t['status'] == 'inProgress')
      .map((t) => t['id'] as String)
      .lastOrNull;
  bool get running => activeTurn != null;
  void changed() {
    timer ??= Timer(const Duration(milliseconds: 50), () {
      timer = null;
      if (!changes.isClosed) changes.add(null);
    });
  }

  void mergePage(List<Map<String, dynamic>> page, {required bool older}) {
    // Server returns newest first. Existing item positions remain stable.
    if (older) {
      for (final t in page) {
        final id = t['id'] as String;
        ordinals.putIfAbsent(id, () => --minOrdinal);
        turns[id] = t;
      }
    } else {
      for (final t in page.reversed) {
        upsertTurn(t);
      }
    }
  }

  void upsertTurn(Map<String, dynamic> t) {
    final id = t['id'] as String;
    ordinals.putIfAbsent(id, () => ++maxOrdinal);
    final old = turns[id];
    // Completion notifications normally carry a summary (often only the
    // final answer), not a replacement transcript. Preserve item identity and
    // arrival order; only an explicitly full history view can replace them.
    final incoming = rows(t['items']);
    final merged = <String, Map<String, dynamic>>{
      for (final item in rows(old?['items'])) item['id'] as String: item,
    };
    for (final item in incoming) {
      final iid = item['id'] as String;
      merged[iid] = {...?merged[iid], ...item};
    }
    turns[id] = {
      ...?old,
      ...t,
      'items': t['itemsView'] == 'full' ? incoming : merged.values.toList(),
    };
  }

  void upsertItem(
    String tid,
    Map<String, dynamic> item, {
    required bool complete,
  }) {
    if (!turns.containsKey(tid))
      upsertTurn({'id': tid, 'status': 'inProgress', 'items': []});
    final items = rows(turns[tid]!['items']);
    final index = items.indexWhere((e) => e['id'] == item['id']);
    final next = {...item, '_complete': complete};
    if (index < 0) {
      items.add(next);
    } else {
      items[index] = {...items[index], ...next};
    }
    turns[tid]!['items'] = items;
  }

  void delta(Map<String, dynamic> p, String method) {
    final tid = p['turnId']?.toString(), iid = p['itemId']?.toString();
    if (tid == null || iid == null) return;
    final item = rows(turns[tid]?['items'])
        .where((i) => i['id'] == iid)
        .firstOrNull;
    if (item == null) return;
    if (method == 'item/agentMessage/delta' || method == 'item/plan/delta') {
      item['text'] = '${item['text'] ?? ''}${p['delta'] ?? ''}';
    } else if (method.contains('outputDelta')) {
      item['aggregatedOutput'] =
          '${item['aggregatedOutput'] ?? ''}${p['delta'] ?? ''}';
    } else if (method.contains('reasoning')) {
      item['_reasoning'] = '${item['_reasoning'] ?? ''}${p['delta'] ?? ''}';
    }
    upsertItem(tid, item, complete: false);
  }

  List<SessionLogEvent> events() {
    final out = <SessionLogEvent>[];
    final ordered = turns.values.toList()
      ..sort((a, b) => ordinals[a['id']]!.compareTo(ordinals[b['id']]!));
    for (final turn in ordered) {
      final ordinal = ordinals[turn['id']]!;
      final base = ordinal * 1000000;
      final items = rows(turn['items']);
      final time =
          ((turn['startedAt'] as num?) ?? (thread['createdAt'] as num?) ?? 0)
              .toInt() *
          1000;
      void add(int seq, String type, Map<String, dynamic> data, [int? when]) =>
          out.add(
            SessionLogEvent.fromJson({
              'seq': seq,
              'time': when ?? time,
              'type': type,
              'data': {'turn': ordinal, 'step': seq - base, ...data},
            }),
          );
      add(base, 'turn/start', {});
      for (var i = 0; i < items.length; i++) {
        final item = items[i], type = item['type'];
        final seq = base + 1 + i * 4;
        final when = (item['startedAtMs'] as num?)?.toInt();
        Map<String, dynamic> message(String role, List<Object?> content) => {
          'id': item['id'],
          'role': role,
          'content': content,
          'source': {'kind': 'user'},
        };
        if (type == 'userMessage') {
          final content = _userContent(item);
          final m = message('user', content);
          m['source'] = {
            'kind': 'user',
            'rpcId': item['clientId'] ?? echoes[item['id']],
          };
          add(seq, 'user/message', m, when);
        } else if (type == 'agentMessage' ||
            type == 'plan' ||
            type == 'reasoning') {
          final text = type == 'reasoning'
              ? (item['_reasoning'] ??
                    (item['summary'] as List? ?? []).join('\n'))
              : item['text'] ?? '';
          add(seq, 'assistant/message', {
            'message': message('assistant', [
              {
                'type': type == 'reasoning' ? 'reasoning' : 'text',
                'text': text,
              },
            ]),
          }, when);
        } else {
          final args = type == 'dynamicToolCall'
              ? obj(item['arguments'])
              : type == 'imageGeneration'
              ? {'prompt': item['revisedPrompt']}
              : type == 'commandExecution'
              ? {
                  'command': item['command'],
                  'cwd': item['cwd'],
                  if (item['aggregatedOutput'] != null)
                    'output': item['aggregatedOutput'],
                }
              : type == 'fileChange'
              ? {'changes': item['changes']}
              : obj(item['arguments']).isNotEmpty
              ? obj(item['arguments'])
              : item;
          add(seq, 'tool/call', {
            'callId': item['id'],
            'name': item['tool'] ?? type ?? 'tool',
            'arguments': jsonEncode(args),
          }, when);
          final complete =
              item['_complete'] == true ||
              turn['status'] != 'inProgress' ||
              ['completed', 'failed', 'declined'].contains(item['status']);
          if (complete) {
            final text = type == 'dynamicToolCall'
                ? rows(item['contentItems'])
                      .where((c) => c['type'] == 'inputText')
                      .map((c) => c['text'] ?? '')
                      .join('\n')
                : type == 'imageGeneration'
                ? (item['failure'] ?? item['status'] ?? '')
                : item['aggregatedOutput'] ??
                      item['result'] ??
                      item['changes'] ??
                      item['output'] ??
                      item['text'] ??
                      item;
            add(seq + 1, 'tool/result', {
              'message': {
                ...message('tool', [
                  ..._toolImages(item),
                  if (type == 'imageGeneration' &&
                      (item['savedPath'] is String || item['result'] is String))
                    {
                      'type': 'image',
                      'attachment': {
                        'attachmentId': 'codex-generated:${item['id']}',
                        'mediaType': 'image/png',
                        'name': 'generated.png',
                      },
                    },
                  {
                    'type': 'text',
                    'text': text is String ? text : jsonEncode(text),
                  },
                ]),
                'toolCallId': item['id'],
                'isError':
                    item['status'] == 'failed' || item['success'] == false,
              },
            }, when);
          }
        }
      }
      if (turn['status'] != 'inProgress')
        add(
          base + 999999,
          'turn/end',
          {
            'reason': {
              'kind': turn['status'] == 'interrupted'
                  ? 'aborted'
                  : turn['status'] == 'failed'
                  ? 'error'
                  : 'completed',
            },
          },
          (turn['completedAt'] as num?)?.toInt() != null
              ? (turn['completedAt'] as num).toInt() * 1000
              : turn['durationMs'] is num
              ? time + (turn['durationMs'] as num).toInt()
              : time,
        );
    }
    return out;
  }

  SessionSnapshotEvent snapshot(
    SessionProjections projections,
    SessionFollowEpoch epoch,
  ) {
    final log = events();
    ActiveAttempt? active;
    final turn = turns[activeTurn];
    if (turn != null) {
      final items = rows(turn['items']);
      for (var i = items.length - 1; i >= 0; i--) {
        final item = items[i];
        if (!['agentMessage', 'plan', 'reasoning'].contains(item['type']) ||
            item['_complete'] == true)
          continue;
        final ordinal = ordinals[turn['id']]!;
        final seq = ordinal * 1000000 + 1 + i * 4;
        final text = item['type'] == 'reasoning'
            ? (item['_reasoning'] ??
                      (item['summary'] as List? ?? []).join('\n'))
                  .toString()
            : (item['text'] ?? '').toString();
        active = ActiveAttempt(
          attemptId: item['id'] as String,
          startedAfterSeq: seq - 1,
          turn: ordinal,
          step: seq - ordinal * 1000000,
          nextIndex: 1,
          chunks: [
            TimedChunk(
              DateTime.fromMillisecondsSinceEpoch(0),
              item['type'] == 'reasoning'
                  ? ReasoningDeltaChunk(0, text)
                  : TextDeltaChunk(0, text),
            ),
          ],
        );
        log.removeWhere((e) => e.seq == seq);
        break;
      }
    }
    return SessionSnapshotEvent(
      sessionId: id,
      header: SessionHeader(
        id: id,
        version: 1,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          ((thread['createdAt'] as num?) ?? 0).toInt() * 1000,
        ),
        isSeeded: true,
        cwd: thread['cwd'] as String?,
      ),
      cursor: log.isEmpty ? -1 : log.last.seq,
      events: log,
      hasMore: cursor != null,
      projections: projections,
      assistantRevision: null,
      activeAttempt: active,
      followEpoch: epoch,
    );
  }
}

/// Adapts only connection lifecycle into the legacy mux. Chat data is handled
/// by typed overrides above; no fake DSH RPC successes or synthetic API server.
class _LifecycleCarrier extends DshCarrier {
  _LifecycleCarrier(this.rpc, this.home);
  final CodexRpc rpc;
  final String home;
  Future<RpcResult> Function(String, Map<String, Object?>)? fileCall;
  @override
  String get kind => 'codex';
  @override
  DshTracer? get tracer => null;
  @override
  bool get supportsUplink => false;
  @override
  bool allowsEndpoint(String endpoint) => false;
  @override
  Future<RpcResult> call(
    String endpoint,
    Map<String, Object?> args, {
    Duration? timeout,
  }) async => fileCall != null && endpoint.startsWith('workspaceFiles/')
      ? await fileCall!(endpoint, args)
      : const RpcError(unsupported);
  @override
  Future<DshMuxLink> openLink(MuxOptions options) async =>
      _LifecycleLink(rpc, home);
  @override
  Future<void> close() => rpc.close();
}

class _LifecycleLink implements DshMuxLink {
  _LifecycleLink(this.rpc, this.home);
  final CodexRpc rpc;
  final String home;
  late DshMuxFrameHandler frame;
  bool closed = false;
  @override
  void start({
    required DshMuxFrameHandler onFrame,
    required DshMuxLossHandler onLost,
  }) {
    frame = onFrame;
    rpc.done.then((_) {
      if (!closed)
        onLost(const DshCarrierLostException('Codex disconnected'), null);
    });
  }

  @override
  void open(String id, String endpoint, Map<String, Object?> payload) {
    scheduleMicrotask(() {
      if (closed) return;
      frame(
        endpoint == r'$events'
            ? {
                'type': 'item',
                'streamId': id,
                'value': {
                  'type': 'ready',
                  'clientId': 'codex-${identityHashCode(this)}',
                  'host': {'home': home},
                },
              }
            : {
                'type': 'error',
                'streamId': id,
                'error': {
                  'code': 'METHOD_NOT_ALLOWED',
                  'message': 'Codex 不支持此功能',
                },
              },
      );
    });
  }

  @override
  void sendItem(String id, Object? value) => throw unsupported;
  @override
  void endUplink(String id) {}
  @override
  void cancel(String id) {}
  @override
  Future<void> close(int code, String reason) async {
    closed = true;
  }
}
