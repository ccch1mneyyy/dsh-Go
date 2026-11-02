import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:dsh_client/src/background_follow.dart';
import 'package:test/test.dart';

Map<String, Object?> _record(int seq) => {
  'event': {
    'seq': seq,
    'time': seq,
    'type': 'user/message',
    'data': {
      'source': {'kind': 'user'},
      'content': [
        {'type': 'text', 'text': 'message $seq'},
      ],
    },
  },
};

void main() {
  test('small baselines and ordinary events keep the synchronous path', () {
    final event = decodeFollowBaseline('s', {
      'type': 'snapshot',
      'cursor': 0,
      'records': [_record(0)],
    });
    expect(event, isA<SessionSnapshotEvent>());
    expect((event as SessionSnapshotEvent).events.single.seq, 0);
    expect(decodeFollowBaseline('s', {'type': 'event', 'event': _record(0)['event']}), isA<UserMessageEvent>());
    expect(decodeFollowBaseline('s', {'type': 'new-host-frame'}), isA<UnknownFrameEvent>());
  });

  test('large baselines decode all records off-isolate without inventing ownership', () async {
    final decoded = decodeFollowBaseline('s', {
      'type': 'snapshot',
      'cursor': 999,
      'hasMore': true,
      'records': List.generate(1000, _record),
    }, isResync: true);
    expect(decoded, isA<Future<DshEvent>>());
    final event = await decoded as SessionSnapshotEvent;
    expect(event.sessionId, 's');
    expect(event.cursor, 999);
    expect(event.isResync, isTrue);
    expect(event.hasMore, isTrue);
    expect(event.followEpoch, isNull);
    expect(event.events.map((e) => e.seq), orderedEquals(List.generate(1000, (i) => i)));
    expect((event.events.last as UserMessageEvent).message.text, 'message 999');
  });

  for (final type in ['text-chunks', 'reasoning-chunks', 'tool-call-chunks']) {
    test('one compact $type record with many tokens takes the background path', () async {
      final members = List.generate(1000, (i) => '$i ');
      final decoded = decodeFollowBaseline('s', {
        'type': 'snapshot',
        'cursor': -1,
        'records': <Object?>[],
        'assistantStream': {
          'revision': 1000,
          'activeAttempt': {
            'attemptId': 'a',
            'turn': 1,
            'step': 2,
            'startedAfterSeq': -1,
            'nextIndex': 1000,
            'stream': [
              {
                'type': type,
                'index': 0,
                'time0': 1000,
                'dt': List.filled(999, 2),
                if (type == 'tool-call-chunks') 'args': members else 'texts': members,
                if (type == 'tool-call-chunks') ...{'id': 'call', 'name': 'tool'},
              },
            ],
          },
        },
      });
      expect(decoded, isA<Future<DshEvent>>());
      final event = await decoded as SessionSnapshotEvent;
      expect(event.assistantRevision, 1000);
      expect(event.activeAttempt!.nextIndex, 1000);
      final chunks = event.activeAttempt!.chunks;
      expect(chunks, hasLength(1000));
      expect(chunks.last.time.millisecondsSinceEpoch, 2998);
      expect(chunks.last.chunk, switch (type) {
        'text-chunks' => isA<TextDeltaChunk>().having((c) => c.text, 'text', members.last),
        'reasoning-chunks' => isA<ReasoningDeltaChunk>().having((c) => c.text, 'text', members.last),
        _ => isA<ToolCallDeltaChunk>().having((c) => c.argumentsDelta, 'args', members.last),
      });
    });
  }
}
