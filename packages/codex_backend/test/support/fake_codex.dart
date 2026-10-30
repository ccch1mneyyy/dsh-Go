import 'dart:async';

import 'package:codex_client/codex_client.dart';

class Fake implements CodexRpc {
  final bus = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final end = Completer<void>();
  final calls = <({String method, Map<String, dynamic> args})>[];
  final answers = <Map<String, dynamic>>[];
  final thread = <String, dynamic>{
    'id': 't',
    'name': 'Native chat',
    'preview': 'hello',
    'createdAt': 1,
    'updatedAt': 2,
    'cwd': '/work',
    'model': 'm',
    'status': {'type': 'idle'},
  };
  List<Map<String, dynamic>> turns = [
    {
      'id': 'old',
      'status': 'completed',
      'items': [
        {
          'id': 'u',
          'type': 'userMessage',
          'content': [
            {'type': 'text', 'text': 'hello'},
          ],
        },
        {'id': 'a', 'type': 'agentMessage', 'text': 'world'},
      ],
    },
  ];
  Map<String, dynamic> account = {
    'type': 'chatgpt',
    'email': 'test@example.invalid',
  };
  void Function()? onPage;
  String? nextCursor;
  bool unpersisted = false;
  bool failSend = false;
  int sends = 0;
  @override
  Stream<Map<String, dynamic>> get messages => bus.stream;
  @override
  Future<void> get done => end.future;
  @override
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, dynamic> args,
  ) async {
    calls.add((method: method, args: args));
    switch (method) {
      case 'account/read':
        return {'account': account};
      case 'thread/name/set':
        thread['name'] = args['name'];
        return {};
      case 'thread/list':
        return {
          'data': args['archived'] == true || unpersisted ? [] : [thread],
        };
      case 'thread/resume':
        if (unpersisted)
          throw const CodexRpcException(
            -32600,
            'Cannot resume an unpersisted thread',
          );
        return {'thread': thread};
      case 'thread/start':
      case 'thread/read':
        return {'thread': thread};
      case 'thread/turns/list':
        if (unpersisted)
          throw const CodexRpcException(-32600, 'No persisted history yet');
        onPage?.call();
        return {
          'data': args['cursor'] == null
              ? turns
              : [
                  {
                    'id': 'older',
                    'status': 'completed',
                    'items': [
                      {
                        'id': 'x',
                        'type': 'userMessage',
                        'content': [
                          {'type': 'text', 'text': 'oldest'},
                        ],
                      },
                    ],
                  },
                ],
          'nextCursor': args['cursor'] == null ? nextCursor : null,
        };
      case 'turn/start':
        sends++;
        unpersisted = false;
        if (failSend) throw TimeoutException('test');
        return {
          'turn': {'id': 'live', 'status': 'inProgress', 'items': []},
        };
      case 'turn/steer':
        return {'turnId': 'live'};
      case 'model/list':
        return {
          'data': [
            {
              'id': 'm',
              'model': 'm',
              'displayName': 'Model',
              'isDefault': true,
              'defaultReasoningEffort': 'low',
              'supportedReasoningEfforts': [
                {'reasoningEffort': 'low'},
              ],
            },
          ],
        };
      default:
        return {};
    }
  }

  @override
  void respond(Object id, {Map<String, dynamic>? result, String? error}) =>
      answers.add({'id': id, 'result': result, 'error': error});
  void notify(String method, Map<String, dynamic> params, {Object? id}) =>
      bus.add({'method': method, 'params': params, if (id != null) 'id': id});
  @override
  Future<void> close() async {
    if (!end.isCompleted) end.complete();
    unawaited(bus.close());
  }
}
