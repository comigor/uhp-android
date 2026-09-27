import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:uhp_android/main.dart';

const _server = ServerConfig(
  id: 'server',
  name: 'Server',
  baseUrl: 'https://example.test',
  apiKey: ' key ',
  accessTokenId: ' edge-id ',
  accessToken: ' edge-token ',
);

class _Client extends http.BaseClient {
  _Client(this.respond);
  final Future<http.StreamedResponse> Function(http.BaseRequest) respond;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      respond(request);

  @override
  void close() => closed = true;
}

http.StreamedResponse _json(Map<String, dynamic> record) =>
    http.StreamedResponse(Stream.value(utf8.encode(jsonEncode(record))), 200);

ConversationThread _pending() => ConversationThread(
  id: 'thread',
  title: 'Question',
  server: _server,
  harnessId: 'harness',
  harnessName: 'Harness',
  serverSessionId: 'session',
  serverLastResponseId: 'previous',
  serverSessionStatus: 'running',
  createdAt: DateTime.utc(2026, 1, 1),
  updatedAt: DateTime.utc(2026, 1, 2),
  messages: [
    ThreadMessage(
      role: 'user',
      text: 'Question',
      createdAt: DateTime.utc(2026, 1, 1),
    ),
    ThreadMessage(
      role: 'assistant',
      text: 'Partial',
      responseId: 'response',
      sessionId: 'session',
      status: TurnStatus.serverContinuing,
      usage: const TokenUsage(outputTokens: 3),
      createdAt: DateTime.utc(2026, 1, 1),
    ),
  ],
);

void main() {
  group('persisted continuation reconciliation', () {
    late Directory directory;
    late ThreadStore store;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('uhp-continuation-');
      store = ThreadStore(() async => directory);
      await store.save(_pending());
    });
    tearDown(() async => directory.delete(recursive: true));

    test(
      'completion replaces one partial and survives restart with identities',
      () async {
        final before = _pending();
        await store.settleResponse('thread', 'response', {
          'id': 'response',
          'status': 'completed',
          'output': [
            null,
            42,
            {
              'role': 'tool',
              'content': [
                {'text': 'Not an answer'},
              ],
            },
            {
              'role': 'assistant',
              'content': [
                null,
                {},
                {'text': 7},
                {'text': 'Final'},
              ],
            },
          ],
          'usage': {'output_tokens': 8, 'input_tokens': 'future shape'},
        });
        store = ThreadStore(() async => directory);
        final restored = (await store.read('thread'))!;
        expect(restored.messages.map((row) => row.text), ['Question', 'Final']);
        expect(restored.messages.last.status, TurnStatus.completed);
        expect(
          restored.messages.last.createdAt,
          before.messages.last.createdAt,
        );
        expect(restored.createdAt, before.createdAt);
        expect(restored.messages.last.responseId, 'response');
        expect(restored.messages.last.sessionId, 'session');
        expect(restored.messages.last.usage?.outputTokens, 8);
        expect(restored.lastResponseId, 'response');
        expect(restored.serverSessionStatus, 'completed');
        expect(await store.continuingThreads(), isEmpty);
        expect(
          await store.settleResponse('thread', 'response', {
            'id': 'response',
            'status': 'failed',
          }),
          isNull,
        );
      },
    );

    test(
      'completed empty output removes partial rather than preserving it',
      () async {
        await store.settleResponse('thread', 'response', {
          'id': 'response',
          'status': 'completed',
          'output': {'unknown': true},
        });
        expect((await store.read('thread'))!.messages.last.text, isEmpty);
      },
    );

    test('unfinished records retain pause timestamp, then incomplete preserves partial', () async {
      for (final status in ['running', 'in_progress', 'queued']) {
        await store.settleResponse('thread', 'response', {
          'id': 'response',
          'status': status,
        });
        expect((await store.read('thread'))!.updatedAt, _pending().updatedAt);
        expect((await store.continuingThreads()).single.id, 'thread');
      }
      await store.settleResponse('thread', 'response', {
        'id': 'response',
        'status': 'incomplete',
        'incomplete_details': {'reason': 'max_output_tokens'},
      });
      final restored = (await ThreadStore(() async => directory)
          .read('thread'))!;
      expect(restored.messages.last.text, 'Partial');
      expect(restored.messages.last.status, TurnStatus.failed);
      expect(restored.messages.last.error, contains('max_output_tokens'));
      expect(restored.lastResponseId, 'previous');
      expect(restored.serverSessionStatus, 'failed');
    });

    test(
      'failure persists readable error while cancellation preserves partial',
      () async {
        await store.settleResponse('thread', 'response', {
          'id': 'response',
          'status': 'error',
          'error': {'message': 'Provider unavailable'},
        });
        var restored = (await store.read('thread'))!;
        expect(restored.messages.last.error, 'Provider unavailable');
        expect(restored.messages.last.text, 'Partial');
        await store.save(_pending());
        await store.settleResponse('thread', 'response', {
          'id': 'response',
          'status': 'cancelled',
        });
        restored = (await store.read('thread'))!;
        expect(restored.messages.last.status, TurnStatus.cancelled);
        expect(restored.messages.last.text, 'Partial');
        expect(restored.lastResponseId, 'previous');
      },
    );

    test(
      'late settlement does not replace a newer turn or regress its pointer',
      () async {
        final newer = _pending().appendTurn(
          'Later',
          const ResponseRecord(
            prompt: 'Later',
            output: 'New answer',
            responseId: 'new-response',
            sessionId: 'session',
          ),
        );
        final saving = store.save(newer);
        final settling = store.settleResponse('thread', 'response', {
          'id': 'response',
          'status': 'completed',
          'output': [],
        });
        await saving;
        await settling;
        final restored = (await store.read('thread'))!;
        expect(restored.messages.last.text, 'New answer');
        expect(restored.lastResponseId, 'new-response');
        expect(restored.messages.length, 4);
        expect(restored.messages[1].status, TurnStatus.completed);
      },
    );

    test(
      'deletion wins queued reconciliation without recreating thread',
      () async {
        final deleting = store.delete('thread');
        final settling = store.settleResponse('thread', 'response', {
          'id': 'response',
          'status': 'completed',
        });
        await deleting;
        expect(await settling, isNull);
        expect(await store.read('thread'), isNull);
        expect(await store.loadIndex(), isEmpty);
      },
    );

    test(
      'mismatched response identity cannot settle the pending message',
      () async {
        await expectLater(
          store.settleResponse('thread', 'response', {
            'id': 'other',
            'status': 'completed',
            'output': [],
          }),
          throwsA(isA<AppError>()),
        );
        final restored = (await store.read('thread'))!;
        expect(restored.messages.last.text, 'Partial');
        expect(restored.hasServerContinuing, isTrue);
      },
    );

    test(
      'older interrupted records remain readable and are never polled',
      () async {
        final legacy = _pending().toJson();
        final messages = legacy['messages'] as List;
        final answer = messages.last as Map;
        answer['status'] = 'interrupted';
        answer.remove('error');
        await store.save(ConversationThread.fromJson(legacy));
        store = ThreadStore(() async => directory);
        expect(await store.continuingThreads(), isEmpty);
        final restored = (await store.read('thread'))!;
        expect(restored.messages.last.status, TurnStatus.interrupted);
        expect(restored.messages.last.text, 'Partial');
        expect(restored.messages.last.error, isNull);
      },
    );

    test(
      'session refresh cannot append a duplicate final answer while pending',
      () async {
        final reopened = await store.linkServerSession(
          server: _server,
          session: const ServerSession(
            id: 'session',
            status: 'completed',
            lastResponseId: 'response',
          ),
          turns: const [
            SessionTurn(role: 'user', text: 'Question'),
            SessionTurn(role: 'assistant', text: 'Final'),
          ],
          harnessName: 'Harness',
        );
        expect(reopened.messages.map((row) => row.text), [
          'Question',
          'Partial',
        ]);
        expect(reopened.hasServerContinuing, isTrue);
        expect(reopened.lastResponseId, 'previous');
      },
    );
  });

  group('response fetch cancellation', () {
    test('authenticated fetch validates identity instead of accepting another response', () async {
      final client = _Client((request) async {
        expect(
          request.url.toString(),
          'https://example.test/api/harness/v1/responses/id%2Fone',
        );
        expect(request.headers['Authorization'], 'Bearer key');
        expect(request.headers['P-Access-Token-Id'], 'edge-id');
        expect(request.headers['P-Access-Token'], 'edge-token');
        expect(request.followRedirects, isFalse);
        return _json({'id': 'other', 'status': 'completed'});
      });
      await expectLater(
        UhpService(client).fetchResponse(_server, 'id/one'),
        throwsA(isA<AppError>()),
      );
      expect(client.closed, isFalse);
    });

    test(
      'abort before headers returns promptly and releases a late body',
      () async {
        final headers = Completer<http.StreamedResponse>();
        final sent = Completer<void>();
        final cancelled = Completer<void>();
        final body = StreamController<List<int>>(onCancel: cancelled.complete);
        final abort = Completer<void>();
        final client = _Client((_) {
          sent.complete();
          return headers.future;
        });
        final result = UhpService(client)
            .fetchResponse(_server, 'response', abortTrigger: abort.future);
        final expectation = expectLater(
          result,
          throwsA(isA<http.RequestAbortedException>()),
        );
        await sent.future;
        abort.complete();
        await expectation;
        headers.complete(http.StreamedResponse(body.stream, 200));
        await cancelled.future;
        expect(client.closed, isFalse);
        unawaited(body.close());
      },
    );

    for (final status in [200, 401]) {
      test(
        'abort cancels a stalled $status body without closing shared transport',
        () async {
          final listening = Completer<void>();
          final cancelled = Completer<void>();
          final body = StreamController<List<int>>(
            onListen: listening.complete,
            onCancel: cancelled.complete,
          );
          final abort = Completer<void>();
          var first = true;
          final client = _Client((_) async {
            if (!first) return _json({'id': 'next', 'status': 'completed'});
            first = false;
            return http.StreamedResponse(body.stream, status);
          });
          final service = UhpService(client);
          final result = service.fetchResponse(
            _server,
            'response',
            abortTrigger: abort.future,
          );
          final expectation = expectLater(
            result,
            throwsA(isA<http.RequestAbortedException>()),
          );
          await listening.future;
          abort.complete();
          await expectation;
          await cancelled.future;
          expect(client.closed, isFalse);
          expect((await service.fetchResponse(_server, 'next'))['id'], 'next');
          unawaited(body.close());
        },
      );
    }
  });
}
