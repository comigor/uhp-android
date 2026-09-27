import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uhp_android/main.dart';

class SessionClient extends http.BaseClient {
  SessionClient(this.respond);
  final Future<http.StreamedResponse> Function(http.Request request) respond;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      respond(request as http.Request);
}

http.StreamedResponse jsonResponse(
  Map<String, dynamic> value, [
  int status = 200,
]) =>
    http.StreamedResponse(Stream.value(utf8.encode(jsonEncode(value))), status);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const server = ServerConfig(
    id: 'server-1',
    name: 'Server',
    baseUrl: 'https://example.test',
    apiKey: 'key',
  );
  const session = ServerSession(
    id: 'session-1',
    title: 'Remote conversation',
    model: 'original-model',
    harnessId: 'harness-1',
    status: 'completed',
    lastResponseId: 'response-1',
  );
  const turns = [
    SessionTurn(role: 'system', text: 'Be helpful'),
    SessionTurn(role: 'user', text: 'Question'),
    SessionTurn(role: 'assistant', text: 'Answer'),
  ];
  late Directory documents;
  late ThreadStore store;

  setUp(() async {
    documents = await Directory.systemTemp.createTemp('uhp-session-thread-');
    store = ThreadStore(() async => documents);
  });
  tearDown(() async => documents.delete(recursive: true));

  Future<ConversationThread> link({ServerConfig profile = server}) =>
      store.linkServerSession(
        server: profile,
        session: session,
        turns: turns,
        harnessName: 'Harness',
      );

  Future<ProviderContainer> initialize(http.Client client) async {
    SharedPreferences.setMockInitialValues({
      ServerStore.key: jsonEncode([server.toJson()]),
    });
    final container = ProviderContainer(
      overrides: [
        httpClientProvider.overrideWithValue(client),
        threadStoreProvider.overrideWithValue(store),
      ],
    );
    await container.read(serversProvider.future);
    container.read(threadProvider.notifier).state = await link();
    addTearDown(() {
      container.dispose();
      client.close();
    });
    return container;
  }

  Map<String, dynamic> detail({
    String status = 'completed',
    String? pointer = 'fresh-response',
  }) => {
    'id': session.id,
    'title': session.title,
    'harness_id': 'fresh-harness',
    'model': session.model,
    'status': status,
    'last_response_id': pointer,
  };

  test(
    'concurrent links reuse only the same server identity and URL',
    () async {
      final linked = await Future.wait([link(), link()]);
      expect(linked[0].id, linked[1].id);
      store = ThreadStore(() async => documents);
      final refreshed = await link(
        profile: const ServerConfig(
          id: 'server-1',
          name: 'Renamed server',
          baseUrl: 'https://example.test/',
          apiKey: 'rotated-key',
        ),
      );
      expect(refreshed.id, linked.first.id);
      final restored = (await store.read(refreshed.id))!;
      expect(restored.server.apiKey, 'rotated-key');
      expect(restored.server.name, 'Renamed server');
      final differentHost = await link(
        profile: server.copyWith(baseUrl: 'https://other.test'),
      );
      final differentProfile = await link(
        profile: const ServerConfig(
          id: 'server-2',
          name: 'Other profile',
          baseUrl: 'https://example.test',
          apiKey: 'other-key',
        ),
      );
      expect({refreshed.id, differentHost.id, differentProfile.id}.length, 3);
      expect((await store.loadIndex()).map((row) => row.id).toSet(), {
        refreshed.id,
        differentHost.id,
        differentProfile.id,
      });
    },
  );

  test(
    'reopening preserves local partials and generic transcript roles',
    () async {
      final linked = await link();
      await store.save(
        linked.appendTurn(
          'Follow up',
          const ResponseRecord(
            prompt: 'Follow up',
            output: 'Partial answer',
            responseId: 'partial-response',
            sessionId: 'session-1',
            status: TurnStatus.interrupted,
            usage: TokenUsage(inputTokens: 4, outputTokens: 2, totalTokens: 6),
          ),
        ),
      );
      store = ThreadStore(() async => documents);
      final reopened = await link();
      final restored = (await store.read(reopened.id))!;
      expect(restored.id, linked.id);
      expect(restored.messages.map((row) => row.text), [
        'Be helpful',
        'Question',
        'Answer',
        'Follow up',
        'Partial answer',
      ]);
      expect(restored.messages.first.role, 'system');
      expect(restored.messages.last.status, TurnStatus.interrupted);
      expect(restored.messages.last.responseId, 'partial-response');
      expect(restored.messages.last.usage?.totalTokens, 6);
      expect(restored.lastResponseId, 'response-1');
    },
  );

  test(
    'remote completion and later turns coexist with durable local partials',
    () async {
      final linked = await link();
      final partial = linked.appendTurn(
        'Continue',
        const ResponseRecord(
          prompt: 'Continue',
          output: 'Partial',
          responseId: 'cancelled-response',
          sessionId: 'session-1',
          status: TurnStatus.cancelled,
        ),
      );
      await store.save(partial);
      const freshTurns = [
        ...turns,
        SessionTurn(role: 'user', text: 'Continue'),
        SessionTurn(role: 'assistant', text: 'Complete remote answer'),
        SessionTurn(role: 'user', text: 'Later question'),
        SessionTurn(role: 'assistant', text: 'Later answer'),
      ];
      Future<ConversationThread> reopen(List<SessionTurn> transcript) =>
          store.linkServerSession(
            server: server,
            session: session,
            turns: transcript,
            harnessName: 'Harness',
          );
      final refreshed = await reopen(freshTurns);
      final expected = [
        ...freshTurns.map((row) => row.text),
        'Continue',
        'Partial',
      ];
      expect(refreshed.messages.map((row) => row.text), expected);
      expect(refreshed.messages.last.status, TurnStatus.cancelled);
      expect(refreshed.messages.last.responseId, 'cancelled-response');
      expect(
        refreshed.messages.last.createdAt,
        partial.messages.last.createdAt,
      );
      store = ThreadStore(() async => documents);
      final repeated = await reopen(freshTurns);
      expect(repeated.id, linked.id);
      expect(repeated.messages.map((row) => row.text), expected);
      expect(
        (await store.read(linked.id))!.messages.map((row) => row.text),
        expected,
      );
      expect((await reopen([])).messages.map((row) => row.text), expected);
      expect(
        (await reopen(const [SessionTurn(role: 'unknown', text: '')])).messages
            .map((row) => row.text),
        expected,
      );
    },
  );

  test(
    'remote copies of completed local pairs are not appended twice',
    () async {
      final linked = await link();
      final completed = linked.appendTurn(
        'Next',
        const ResponseRecord(
          prompt: 'Next',
          output: 'Next answer',
          responseId: 'next-response',
          sessionId: 'session-1',
          usage: TokenUsage(inputTokens: 8, outputTokens: 3, totalTokens: 11),
        ),
      );
      await store.save(completed);
      for (var pass = 0; pass < 2; pass++) {
        final reopened = await store.linkServerSession(
          server: server,
          session: session,
          harnessName: 'Harness',
          turns: [
            ...turns,
            const SessionTurn(role: 'user', text: 'Next'),
            const SessionTurn(role: 'assistant', text: 'Next answer'),
          ],
        );
        expect(
          reopened.messages.map((row) => row.text),
          completed.messages.map((row) => row.text),
        );
        expect(reopened.messages.last.responseId, 'next-response');
        expect(reopened.messages.last.usage?.totalTokens, 11);
      }
    },
  );

  test(
    'remote transcript extensions retain existing message metadata',
    () async {
      final linked = await link();
      final reopened = await store.linkServerSession(
        server: server,
        session: session,
        turns: [
          ...turns,
          const SessionTurn(role: 'tool', text: 'Tool result'),
        ],
        harnessName: 'Harness',
      );
      expect(reopened.id, linked.id);
      expect(
        reopened.messages.first.createdAt,
        linked.messages.first.createdAt,
      );
      expect((await store.read(linked.id))!.messages.last.role, 'tool');
      expect(reopened.messages.last.text, 'Tool result');
    },
  );

  test(
    'old saved threads keep their message-derived continuation pointer',
    () async {
      final original = ConversationThread.start(
        server: server,
        harness: const Harness(
          id: 'h1',
          name: 'Harness',
          baseLabel: '',
          defaultModel: '',
        ),
        prompt: 'Legacy question',
        record: const ResponseRecord(
          prompt: 'Legacy question',
          output: 'Legacy answer',
          responseId: 'legacy-response',
          sessionId: 'legacy-session',
        ),
      );
      await store.save(original);
      final legacy = original.toJson()
        ..remove('serverSessionId')
        ..remove('serverHarnessId')
        ..remove('serverLastResponseId')
        ..remove('serverSessionStatus');
      await File('${documents.path}/threads/${original.id}.json')
          .writeAsString(jsonEncode(legacy));
      final restored = (await ThreadStore(() async => documents)
          .read(original.id))!;
      expect(restored.serverSessionId, isNull);
      expect(restored.lastResponseId, 'legacy-response');
      expect(restored.messages.last.text, 'Legacy answer');
    },
  );

  test(
    'completed responses advance the persisted linked pointer, partials do not',
    () async {
      final linked = await link();
      final completed = linked.appendTurn(
        'Next',
        const ResponseRecord(
          prompt: 'Next',
          output: 'Next answer',
          responseId: 'response-2',
          sessionId: 'session-1',
        ),
      );
      await store.save(
        completed.appendTurn(
          'Interrupted',
          const ResponseRecord(
            prompt: 'Interrupted',
            output: '',
            responseId: '',
            sessionId: '',
            status: TurnStatus.interrupted,
          ),
        ),
      );
      final restored = (await ThreadStore(() async => documents)
          .read(linked.id))!;
      expect(restored.serverSessionId, 'session-1');
      expect(restored.serverHarnessId, 'harness-1');
      expect(restored.serverSessionStatus, 'completed');
      expect(restored.lastResponseId, 'response-2');
      expect(restored.messages.last.responseId, isNull);
      expect(restored.messages.last.status, TurnStatus.interrupted);
    },
  );

  test('fresh running status blocks a stale idle linked composer', () async {
    final requests = <String>[];
    final client = SessionClient((request) async {
      requests.add(request.method);
      return jsonResponse(detail(status: 'in_progress'));
    });
    final container = await initialize(client);
    await expectLater(
      container.read(taskRunnerProvider).submit('Next'),
      throwsA(isA<AppError>()),
    );
    expect(requests, ['GET']);
    final linked = container.read(threadProvider)!;
    expect(linked.serverSessionStatus, 'in_progress');
    expect((await store.read(linked.id))!.serverSessionStatus, 'in_progress');
    expect(
      linked.messages.map((row) => row.text),
      turns.map((row) => row.text),
    );
    expect(container.read(taskBusyProvider), isFalse);
    expect(container.read(liveTurnProvider), isNull);
  });

  test('missing fresh pointer blocks sending rather than forking', () async {
    final requests = <String>[];
    final client = SessionClient((request) async {
      requests.add(request.method);
      return jsonResponse(detail(pointer: null));
    });
    final container = await initialize(client);
    await expectLater(
      container.read(taskRunnerProvider).submit('Next'),
      throwsA(isA<AppError>()),
    );
    expect(requests, ['GET']);
    expect(container.read(threadProvider)!.lastResponseId, isNull);
    expect(container.read(taskBusyProvider), isFalse);
  });

  test('failed freshness check never starts a linked response', () async {
    final requests = <String>[];
    final client = SessionClient((request) async {
      requests.add(request.method);
      return jsonResponse({'error': 'unavailable'}, 503);
    });
    final container = await initialize(client);
    await expectLater(
      container.read(taskRunnerProvider).submit('Next'),
      throwsA(isA<ApiException>()),
    );
    expect(requests, ['GET']);
    expect(container.read(threadProvider)!.lastResponseId, 'response-1');
    expect(container.read(taskBusyProvider), isFalse);
  });

  test('Stop uses the linked session before a created event arrives', () async {
    final sent = Completer<void>();
    final bytes = StreamController<List<int>>();
    final cancelled = <String>[];
    final client = SessionClient((request) async {
      if (request.method == 'GET') return jsonResponse(detail());
      if (request.url.path.endsWith('/cancel')) {
        cancelled.add(request.url.path);
        return jsonResponse({});
      }
      sent.complete();
      return http.StreamedResponse(
        bytes.stream,
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    });
    final container = await initialize(client);
    final runner = container.read(taskRunnerProvider);
    final pending = runner.submit('Stop before created');
    await sent.future;
    await runner.cancel();
    await pending;
    expect(cancelled, ['/api/harness/v1/sessions/session-1/cancel']);
    final linked = container.read(threadProvider)!;
    final restored = (await store.read(linked.id))!;
    expect(restored.messages.last.status, TurnStatus.cancelled);
    expect(restored.serverSessionId, 'session-1');
    expect(restored.lastResponseId, 'fresh-response');
    expect(container.read(taskBusyProvider), isFalse);
    await bytes.close();
  });

  test(
    'continuation uses fresh pointer and harness with per-turn optional model',
    () async {
      final bodies = <Map<String, dynamic>>[];
      final client = SessionClient((request) async {
        if (request.method == 'GET') return jsonResponse(detail());
        bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.StreamedResponse(
          Stream.value(
            utf8.encode(
              'data: ${jsonEncode({
                'type': 'response.completed',
                'response': {
                  'id': 'completed-response',
                  'metadata': {'session_id': 'session-1'},
                  'output': [
                    {
                      'role': 'assistant',
                      'content': [
                        {'text': 'New answer'},
                      ],
                    },
                  ],
                },
              })}\n\n',
            ),
          ),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });
      final container = await initialize(client);
      final runner = container.read(taskRunnerProvider);
      await runner.submit('Next', model: 'selected-model');
      expect(bodies.single['previous_response_id'], 'fresh-response');
      expect(bodies.single['metadata']['harness_id'], 'fresh-harness');
      expect(bodies.single['model'], 'selected-model');
      final linked = container.read(threadProvider)!;
      final restored = (await store.read(linked.id))!;
      expect(restored.lastResponseId, 'completed-response');
      expect(restored.serverSessionId, 'session-1');
      expect(restored.serverHarnessId, 'fresh-harness');
      expect(restored.messages.last.text, 'New answer');
      await runner.submit('Without override');
      expect(bodies.last.containsKey('model'), isFalse);
      expect(bodies.last['previous_response_id'], 'fresh-response');
    },
  );
}
