import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uhp_android/main.dart';

class TurnClient extends http.BaseClient {
  TurnClient(this.respond);
  final Future<http.StreamedResponse> Function(http.Request request) respond;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      respond(request as http.Request);
}

List<int> event(Map<String, dynamic> data) =>
    utf8.encode('data: ${jsonEncode(data)}\n\n');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const server = ServerConfig(
    id: 's1',
    name: 'Server',
    baseUrl: 'https://example.test',
    apiKey: 'test-api-key',
    accessTokenId: 'id',
    accessToken: 'token',
  );
  const harness = Harness(
    id: 'h1',
    name: 'Harness',
    baseLabel: '',
    defaultModel: '',
  );
  late Directory documents;
  late ProviderContainer container;

  Future<void> initialize(http.Client client) async {
    SharedPreferences.setMockInitialValues({
      ServerStore.key: jsonEncode([server.toJson()]),
    });
    documents = await Directory.systemTemp.createTemp('uhp-stream-turn-');
    container = ProviderContainer(
      overrides: [
        httpClientProvider.overrideWithValue(client),
        threadStoreProvider.overrideWithValue(
          ThreadStore(() async => documents),
        ),
      ],
    );
    await container.read(serversProvider.future);
    container.read(selectedServerProvider.notifier).state = server;
    container.read(selectedHarnessProvider.notifier).state = harness;
    addTearDown(() async {
      container.dispose();
      client.close();
      await documents.delete(recursive: true);
    });
  }

  test(
    'Stop sends cancel, closes SSE, and persists partial text and IDs',
    () async {
      var closed = false;
      var cancelRequests = 0;
      final sent = Completer<void>();
      final bytes = StreamController<List<int>>(
        onCancel: () {
          closed = true;
        },
      );
      final client = TurnClient((request) async {
        if (request.url.path.endsWith('/cancel')) {
          cancelRequests++;
          expect(request.method, 'POST');
          expect(request.url.path, '/api/harness/v1/sessions/session-1/cancel');
          expect(request.headers['P-Access-Token'], 'token');
          expect(jsonDecode(request.body), <String, dynamic>{});
          return http.StreamedResponse(Stream.value(utf8.encode('{}')), 409);
        }
        expect(jsonDecode(request.body)['stream'], isTrue);
        sent.complete();
        return http.StreamedResponse(
          bytes.stream,
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });
      await initialize(client);
      final runner = container.read(taskRunnerProvider);
      final live = Completer<void>();
      final listener = container.listen(liveTurnProvider, (_, next) {
        if (next?.progress.text == 'Partial answer' && !live.isCompleted) {
          live.complete();
        }
      });
      addTearDown(listener.close);
      final pending = runner.submit('Question');
      await sent.future;
      bytes.add(
        event({
          'type': 'response.created',
          'response': {
            'id': 'response-1',
            'metadata': {'session_id': 'session-1'},
          },
        }),
      );
      bytes.add(
        event({
          'type': 'response.output_text.delta',
          'delta': 'Partial answer',
        }),
      );
      await live.future;
      await runner.cancel();
      await pending;
      expect(closed, isTrue);
      expect(cancelRequests, 1);
      expect(container.read(taskBusyProvider), isFalse);
      final thread = container.read(threadProvider)!;
      final restored = (await ThreadStore(() async => documents)
          .read(thread.id))!;
      expect(restored.messages.last.status, TurnStatus.cancelled);
      expect(restored.messages.last.text, 'Partial answer');
      expect(restored.messages.last.sessionId, 'session-1');
      expect(restored.lastResponseId, 'response-1');
      await bytes.close();
    },
  );

  test('background before created saves a recovery error and next turn omits previous ID', () async {
    final bytes = StreamController<List<int>>();
    final sent = Completer<void>();
    var requests = 0;
    final client = TurnClient((request) async {
      expect(request.url.path.endsWith('/cancel'), isFalse);
      requests++;
      if (requests == 1) {
        sent.complete();
        return http.StreamedResponse(
          bytes.stream,
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }
      expect(
        jsonDecode(request.body).containsKey('previous_response_id'),
        isFalse,
      );
      return http.StreamedResponse(
        Stream.value(
          event({
            'type': 'response.completed',
            'response': {
              'id': 'fresh-response',
              'output': [
                {
                  'role': 'assistant',
                  'content': [
                    {'text': 'Fresh answer'},
                  ],
                },
              ],
            },
          }),
        ),
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    });
    await initialize(client);
    final runner = container.read(taskRunnerProvider);
    final first = runner.submit('Backgrounded question');
    await sent.future;
    await runner.background();
    await first;
    final originalId = container.read(threadProvider)!.id;
    final restored = (await ThreadStore(() async => documents)
        .read(originalId))!;
    expect(restored.messages.last.status, TurnStatus.failed);
    expect(
      restored.messages.last.error,
      contains('before the server supplied a response ID'),
    );
    expect(restored.lastResponseId, isNull);
    container.read(threadProvider.notifier).state = restored;
    await runner.submit('Try again');
    final saved = (await ThreadStore(() async => documents).read(originalId))!;
    expect(saved.messages.map((message) => message.text), [
      'Backgrounded question',
      '',
      'Try again',
      'Fresh answer',
    ]);
    expect(saved.lastResponseId, 'fresh-response');
    expect(container.read(threadProvider)!.id, originalId);
    expect(requests, 2);
    await bytes.close();
  });
}
