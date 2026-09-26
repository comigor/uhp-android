import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:uhp_android/main.dart';

const server = ServerConfig(
  name: 'demo',
  baseUrl: 'https://example.test',
  authMode: AuthMode.pangolin,
  accessTokenId: 'token-id',
  accessToken: 'secret',
);
const draft = ResponseDraft(
  input: 'continue',
  harnessId: 'harness-1',
  previousResponseId: 'previous-1',
);

List<int> event(Map<String, dynamic> value) =>
    utf8.encode('data: ${jsonEncode(value)}\n\n');

http.StreamedResponse sse(Stream<List<int>> stream) => http.StreamedResponse(
  stream,
  200,
  headers: <String, String>{'content-type': 'text/event-stream; charset=utf-8'},
);

class ControlledClient extends http.BaseClient {
  ControlledClient(this.handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  final List<http.BaseRequest> requests = <http.BaseRequest>[];
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests.add(request);
    return handler(request);
  }

  @override
  void close() => closed = true;
}

void main() {
  test(
    'SSE handles byte splits, CRLF, comments, multiline data and DONE',
    () async {
      final bytes = utf8.encode(
        ': heartbeat\r\n\r\nevent: response.output_text.delta\r\n'
        'data: {"delta":\r\ndata: "héllo 🌍"}\r\n\r\n'
        'data: [DONE]\n\n'
        'data: {"type":"response.completed","response":{"id":"r"}}\n\n',
      );
      final parsed = await parseSse(
        Stream<List<int>>.fromIterable(bytes.map((byte) => <int>[byte])),
      ).toList();
      expect(parsed, <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'response.output_text.delta',
          'delta': 'héllo 🌍',
        },
        <String, dynamic>{
          'type': 'response.completed',
          'response': <String, dynamic>{'id': 'r'},
        },
      ]);
    },
  );

  test('SSE rejects malformed JSON', () async {
    await expectLater(
      parseSse(Stream<List<int>>.value(utf8.encode('data: {broken}\n\n')))
          .toList(),
      throwsFormatException,
    );
  });

  test(
    'completed uses final output, identity and usage and closes an open stream',
    () async {
      final cancelled = Completer<void>();
      final body = StreamController<List<int>>(onCancel: cancelled.complete);
      final client = ControlledClient((_) async => sse(body.stream));
      final turn = StreamingTurn(client, server, draft);
      final observed = <TurnProgress>[];
      final result = turn.run(onProgress: observed.add);
      body.add(
        event(<String, dynamic>{
          'type': 'response.created',
          'response': <String, dynamic>{
            'id': 'r',
            'metadata': <String, dynamic>{'session_id': 's'},
          },
        }),
      );
      body.add(
        event(<String, dynamic>{
          'type': 'response.output_text.delta',
          'delta': 'partial',
        }),
      );
      for (var i = 0; i < 100; i++) {
        body.add(
          event(<String, dynamic>{
            'type': 'response.output_item.done',
            'item': <String, dynamic>{
              'type': 'function_call',
              'name': 'tool-${i ~/ 2}',
            },
          }),
        );
      }
      body.add(
        event(<String, dynamic>{
          'type': 'response.completed',
          'response': <String, dynamic>{
            'output': <Map<String, dynamic>>[
              <String, dynamic>{
                'role': 'assistant',
                'content': <Map<String, String>>[
                  <String, String>{'text': 'final'},
                ],
              },
            ],
            'usage': <String, int>{
              'input_tokens': 4,
              'output_tokens': 2,
              'total_tokens': 6,
            },
          },
        }),
      );
      final record = await result;
      await cancelled.future;
      expect(record.output, 'final');
      expect(record.responseId, 'r');
      expect(record.sessionId, 's');
      expect(record.status, TurnStatus.completed);
      expect(record.usage?.totalTokens, 6);
      expect(observed.any((value) => value.text == 'partial'), isTrue);
      expect(turn.progress.tools, List<String>.generate(32, (i) => 'tool-$i'));
      expect(turn.finished, isTrue);
      expect(client.closed, isFalse);
      await (client.requests.single as http.AbortableRequest).abortTrigger;
      await body.close();
    },
  );

  test('completed retains deltas when final output is absent', () async {
    final client = ControlledClient(
      (_) async => sse(
        Stream<List<int>>.fromIterable(<List<int>>[
          event(<String, dynamic>{
            'type': 'response.output_text.delta',
            'delta': 'kept',
          }),
          event(<String, dynamic>{
            'type': 'response.completed',
            'response': <String, dynamic>{'id': 'r'},
          }),
        ]),
      ),
    );
    final record = await StreamingTurn(
      client,
      server,
      draft,
    ).run(onProgress: (_) {});
    expect(record.output, 'kept');
  });

  test(
    'stream rejection falls back once with auth and original context',
    () async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        if (requests.length == 1) return http.Response('not supported', 400);
        return http.Response(
          jsonEncode(<String, dynamic>{
            'id': 'legacy',
            'output': <Map<String, dynamic>>[
              <String, dynamic>{
                'role': 'assistant',
                'content': <Map<String, String>>[
                  <String, String>{'text': 'answer'},
                ],
              },
            ],
          }),
          200,
        );
      });
      final result = await StreamingTurn(
        client,
        server,
        draft,
      ).run(onProgress: (_) {});
      expect(result.output, 'answer');
      expect(requests.length, 2);
      for (var i = 0; i < requests.length; i++) {
        expect(requests[i].headers['P-Access-Token-Id'], 'token-id');
        expect(requests[i].headers['P-Access-Token'], 'secret');
        expect(jsonDecode(requests[i].body), <String, dynamic>{
          'input': 'continue',
          'stream': i == 0,
          'metadata': <String, dynamic>{'harness_id': 'harness-1'},
          'previous_response_id': 'previous-1',
        });
      }
    },
  );

  test(
    'first error event retries only once, including failed fallback',
    () async {
      var calls = 0;
      final client = ControlledClient((_) async {
        calls++;
        if (calls == 1) {
          return sse(
            Stream<List<int>>.value(
              event(<String, dynamic>{
                'type': 'error',
                'error': <String, String>{'message': 'stream unsupported'},
              }),
            ),
          );
        }
        return http.StreamedResponse(
          Stream<List<int>>.value(utf8.encode('denied')),
          403,
        );
      });
      await expectLater(
        StreamingTurn(client, server, draft).run(onProgress: (_) {}),
        throwsA(
          isA<AppError>().having(
            (error) => error.message,
            'message',
            contains('403'),
          ),
        ),
      );
      expect(calls, 2);
    },
  );

  test(
    'JSON success on streaming request is completion, not a duplicate request',
    () async {
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return http.Response('{"id":"legacy","output":[]}', 200);
      });
      final result = await StreamingTurn(
        client,
        server,
        draft,
      ).run(onProgress: (_) {});
      expect(result.responseId, 'legacy');
      expect(calls, 1);
    },
  );

  test(
    'failure after accepted event exposes message and keeps partial progress',
    () async {
      final client = ControlledClient(
        (_) async => sse(
          Stream<List<int>>.fromIterable(<List<int>>[
            event(<String, dynamic>{
              'type': 'response.output_text.delta',
              'delta': 'partial',
            }),
            event(<String, dynamic>{
              'type': 'response.failed',
              'response': <String, dynamic>{
                'error': <String, String>{'message': 'model unavailable'},
              },
            }),
          ]),
        ),
      );
      final turn = StreamingTurn(client, server, draft);
      await expectLater(
        turn.run(onProgress: (_) {}),
        throwsA(
          isA<AppError>().having(
            (error) => error.message,
            'message',
            'model unavailable',
          ),
        ),
      );
      expect(turn.progress.text, 'partial');
      expect(client.requests.length, 1);
      expect(turn.finished, isTrue);
    },
  );

  test(
    'unrecognized real SSE event forbids retry on a subsequent failure',
    () async {
      final client = ControlledClient(
        (_) async => sse(
          Stream<List<int>>.fromIterable(<List<int>>[
            event(<String, dynamic>{'type': 'response.in_progress'}),
            event(<String, dynamic>{
              'type': 'error',
              'message': 'already executing',
            }),
          ]),
        ),
      );
      await expectLater(
        StreamingTurn(client, server, draft).run(onProgress: (_) {}),
        throwsA(
          isA<AppError>().having(
            (error) => error.message,
            'message',
            'already executing',
          ),
        ),
      );
      expect(client.requests.length, 1);
    },
  );

  test('DONE without completed is not a successful response', () async {
    final client = ControlledClient(
      (_) async =>
          sse(Stream<List<int>>.value(utf8.encode('data: [DONE]\n\n'))),
    );
    await expectLater(
      StreamingTurn(client, server, draft).run(onProgress: (_) {}),
      throwsA(
        isA<AppError>().having(
          (error) => error.message,
          'message',
          contains('before completion'),
        ),
      ),
    );
    expect(client.requests.length, 1);
  });

  test('stop is idempotent, preserves partial text, cancels stream and aborts request', () async {
    final cancelled = Completer<void>();
    final partial = Completer<void>();
    final body = StreamController<List<int>>(onCancel: cancelled.complete);
    final client = ControlledClient((_) async => sse(body.stream));
    final turn = StreamingTurn(client, server, draft);
    final result = turn.run(
      onProgress: (progress) {
        if (progress.text == 'partial' && !partial.isCompleted) {
          partial.complete();
        }
      },
    );
    body.add(
      event(<String, dynamic>{
        'type': 'response.output_text.delta',
        'delta': 'partial',
      }),
    );
    await partial.future;
    await turn.stop(TurnStatus.cancelled);
    await turn.stop(TurnStatus.interrupted);
    final record = await result;
    await cancelled.future;
    await (client.requests.single as http.AbortableRequest).abortTrigger;
    expect(record.status, TurnStatus.cancelled);
    expect(record.output, 'partial');
    expect(client.closed, isFalse);
    await body.close();
  });

  test(
    'stop interrupts pending headers and disposes a late response',
    () async {
      final headers = Completer<http.StreamedResponse>();
      final cancelled = Completer<void>();
      final body = StreamController<List<int>>(onCancel: cancelled.complete);
      final client = ControlledClient((_) => headers.future);
      final turn = StreamingTurn(client, server, draft);
      final result = turn.run(onProgress: (_) {});
      await turn.stop(TurnStatus.interrupted);
      expect((await result).status, TurnStatus.interrupted);
      await (client.requests.single as http.AbortableRequest).abortTrigger;
      headers.complete(sse(body.stream));
      await cancelled.future;
      expect(client.closed, isFalse);
      await body.close();
    },
  );

  test(
    'stop interrupts pending fallback headers without closing shared client',
    () async {
      final fallbackStarted = Completer<void>();
      final fallback = Completer<http.StreamedResponse>();
      var calls = 0;
      final client = ControlledClient((_) async {
        if (++calls == 1) {
          return http.StreamedResponse(const Stream<List<int>>.empty(), 400);
        }
        fallbackStarted.complete();
        return fallback.future;
      });
      final turn = StreamingTurn(client, server, draft);
      final result = turn.run(onProgress: (_) {});
      await fallbackStarted.future;
      await turn.stop(TurnStatus.cancelled);
      expect((await result).status, TurnStatus.cancelled);
      await (client.requests.last as http.AbortableRequest).abortTrigger;
      fallback.complete(
        http.StreamedResponse(const Stream<List<int>>.empty(), 200),
      );
      expect(calls, 2);
      expect(client.closed, isFalse);
    },
  );

  test(
    'stop closes a pending fallback body and returns without its response',
    () async {
      final listening = Completer<void>();
      final cancelled = Completer<void>();
      final body = StreamController<List<int>>(
        onListen: listening.complete,
        onCancel: cancelled.complete,
      );
      var calls = 0;
      final client = ControlledClient((_) async {
        if (++calls == 1) {
          return http.StreamedResponse(const Stream<List<int>>.empty(), 400);
        }
        return http.StreamedResponse(body.stream, 200);
      });
      final turn = StreamingTurn(client, server, draft);
      final result = turn.run(onProgress: (_) {});
      await listening.future;
      body.add(utf8.encode('{"id":'));
      await turn.stop(TurnStatus.cancelled);
      expect((await result).status, TurnStatus.cancelled);
      await cancelled.future;
      expect(calls, 2);
      await body.close();
    },
  );

  test('idle timeout ignores comments and closes the stalled stream', () async {
    final cancelled = Completer<void>();
    final body = StreamController<List<int>>(onCancel: cancelled.complete);
    final client = ControlledClient((_) async => sse(body.stream));
    final turn = StreamingTurn(
      client,
      server,
      draft,
      idleTimeout: const Duration(milliseconds: 10),
    );
    final result = turn.run(onProgress: (_) {});
    body.add(utf8.encode(': heartbeat\n\ndata: {"type":"unrelated"}\n\n'));
    await expectLater(result, throwsA(isA<AppError>()));
    await cancelled.future;
    expect(client.requests.length, 1);
    await body.close();
  });

  test(
    'cancel endpoint encodes session id and accepts terminal conflicts',
    () async {
      final request = buildCancelRequest(server, 'session/a b');
      expect(
        request.url.toString(),
        'https://example.test/v1/sessions/session%2Fa%20b/cancel',
      );
      expect(request.method, 'POST');
      expect(jsonDecode(request.body), <String, dynamic>{});
      expect(request.headers['P-Access-Token'], 'secret');
      for (final status in <int>[200, 204, 404, 409]) {
        await sendSessionCancel(
          MockClient((_) async => http.Response('', status)),
          server,
          's',
        );
      }
      await expectLater(
        sendSessionCancel(
          MockClient((_) async => http.Response('denied', 403)),
          server,
          's',
        ),
        throwsA(
          isA<ApiException>().having(
            (error) => error.statusCode,
            'statusCode',
            403,
          ),
        ),
      );
    },
  );
}
