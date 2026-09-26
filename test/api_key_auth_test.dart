import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/io_client.dart';
import 'package:uhp_android/main.dart';

const _draft = ResponseDraft(
  input: 'Continue',
  harnessId: 'fixture-harness',
  previousResponseId: 'fixture-previous',
);
const _edgeMessage =
    'Edge sign-in required: add the Pangolin token pair for this server.';
const _keyMessage = 'Server rejected the API key.';
const _completedEvent =
    'data: {"type":"response.completed","response":{"id":"fixture-next",'
    '"output":[{"role":"assistant","content":[{"text":"Answer"}]}]}}\n\n';

enum _Operation { rest, sse, cancel }

class _ObservedRequest {
  _ObservedRequest(HttpRequest request, this.body)
    : method = request.method,
      uri = request.uri,
      authorization = request.headers.value(HttpHeaders.authorizationHeader),
      tokenId = request.headers.value('P-Access-Token-Id'),
      token = request.headers.value('P-Access-Token'),
      cookie = request.headers.value(HttpHeaders.cookieHeader);

  final String method;
  final Uri uri;
  final String body;
  final String? authorization;
  final String? tokenId;
  final String? token;
  final String? cookie;
}

class _ApiServer {
  _ApiServer(this.server) : client = IOClient(HttpClient());

  final HttpServer server;
  final IOClient client;
  final requests = <_ObservedRequest>[];

  static Future<_ApiServer> start(
    Future<void> Function(HttpRequest request) respond,
  ) async {
    final fixture = _ApiServer(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    addTearDown(() async {
      fixture.client.close();
      await fixture.server.close(force: true);
    });
    fixture.server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      fixture.requests.add(_ObservedRequest(request, body));
      await respond(request);
    });
    return fixture;
  }

  ServerConfig profile({
    String? apiKey = ' fixture-api-key ',
    String? tokenId,
    String? token,
  }) => ServerConfig(
    id: 'fixture-server',
    name: 'Fixture server',
    baseUrl: 'http://127.0.0.1:${server.port}',
    apiKey: apiKey,
    accessTokenId: tokenId,
    accessToken: token,
  );
}

Future<void> _success(HttpRequest request) async {
  if (request.uri.path == '/api/harness/v1/harnesses') {
    request.response.write('{"data":[{"id":"fixture-harness"}]}');
  } else if (request.uri.path == '/api/harness/v1/responses') {
    request.response.headers.contentType = ContentType('text', 'event-stream');
    request.response.write(_completedEvent);
  } else if (request.uri.path.endsWith('/cancel')) {
    request.response.statusCode = HttpStatus.noContent;
  } else {
    request.response.statusCode = HttpStatus.notFound;
  }
  await request.response.close();
}

Future<void> _perform(
  _Operation operation,
  UhpService service,
  ServerConfig profile,
) async {
  switch (operation) {
    case _Operation.rest:
      final harnesses = await service.fetchHarnesses(profile);
      expect(harnesses.single.id, 'fixture-harness');
    case _Operation.sse:
      final result = await service
          .startTurn(profile, _draft)
          .run(onProgress: (_) {});
      expect(result.output, 'Answer');
      expect(result.responseId, 'fixture-next');
      expect(result.status, TurnStatus.completed);
    case _Operation.cancel:
      await service.cancelSession(profile, 'session/a b');
  }
}

String _path(_Operation operation) => switch (operation) {
  _Operation.rest => '/api/harness/v1/harnesses',
  _Operation.sse => '/api/harness/v1/responses',
  _Operation.cancel => '/v1/sessions/session%2Fa%20b/cancel',
};

Matcher _appError(String message) =>
    isA<AppError>().having((error) => error.message, 'message', message);

void main() {
  for (final withPangolin in [false, true]) {
    test(
      'REST, SSE and cancel send bearer with Pangolin=$withPangolin',
      () async {
        final fixture = await _ApiServer.start(_success);
        final service = UhpService(fixture.client);
        final profile = fixture.profile(
          tokenId: withPangolin ? ' fixture-edge-id ' : null,
          token: withPangolin ? ' fixture-edge-token ' : null,
        );

        for (final operation in _Operation.values) {
          await _perform(operation, service, profile);
        }

        expect(
          fixture.requests.map((request) => request.uri.toString()),
          _Operation.values.map(_path),
        );
        expect(fixture.requests.map((request) => request.method), [
          'GET',
          'POST',
          'POST',
        ]);
        for (final request in fixture.requests) {
          expect(request.authorization, 'Bearer fixture-api-key');
          expect(request.tokenId, withPangolin ? 'fixture-edge-id' : null);
          expect(request.token, withPangolin ? 'fixture-edge-token' : null);
          expect(request.cookie, isNull);
        }
        expect(jsonDecode(fixture.requests[1].body), {
          'input': 'Continue',
          'stream': true,
          'metadata': {'harness_id': 'fixture-harness'},
          'previous_response_id': 'fixture-previous',
        });
        expect(jsonDecode(fixture.requests[2].body), isEmpty);
      },
    );
  }

  test('incomplete Pangolin pairs never leak either header', () async {
    final fixture = await _ApiServer.start(_success);
    final service = UhpService(fixture.client);
    for (final pair in const [
      (null, 'fixture-edge-token'),
      ('fixture-edge-id', null),
      (' ', 'fixture-edge-token'),
      ('fixture-edge-id', ' '),
    ]) {
      final profile = fixture.profile(tokenId: pair.$1, token: pair.$2);
      for (final operation in _Operation.values) {
        await _perform(operation, service, profile);
      }
    }
    expect(fixture.requests, hasLength(12));
    for (final request in fixture.requests) {
      expect(request.authorization, 'Bearer fixture-api-key');
      expect(request.tokenId, isNull);
      expect(request.token, isNull);
      expect(request.cookie, isNull);
    }
  });

  test(
    'missing or blank API key blocks every operation before networking',
    () async {
      final fixture = await _ApiServer.start(_success);
      final service = UhpService(fixture.client);
      for (final key in [null, '   ']) {
        final profile = fixture.profile(
          apiKey: key,
          tokenId: 'fixture-edge-id',
          token: 'fixture-edge-token',
        );
        for (final operation in _Operation.values) {
          await expectLater(
            _perform(operation, service, profile),
            throwsA(_appError('API key required')),
          );
        }
      }
      expect(fixture.requests, isEmpty);
    },
  );

  for (final operation in _Operation.values) {
    for (final status in [HttpStatus.found, HttpStatus.seeOther]) {
      test(
        '${operation.name} maps $status without following or retrying',
        () async {
          final fixture = await _ApiServer.start((request) async {
            if (request.uri.path == '/fixture-edge-login') {
              request.response.write('Redirect must not be followed');
            } else {
              request.response.statusCode = status;
              request.response.headers.set(
                HttpHeaders.locationHeader,
                '/fixture-edge-login',
              );
            }
            await request.response.close();
          });

          await expectLater(
            _perform(operation, UhpService(fixture.client), fixture.profile()),
            throwsA(_appError(_edgeMessage)),
          );
          expect(fixture.requests.map((request) => request.uri.toString()), [
            _path(operation),
          ]);
        },
      );
    }

    test(
      '${operation.name} maps invalid API key without login or retry',
      () async {
        final fixture = await _ApiServer.start((request) async {
          request.response.statusCode = HttpStatus.unauthorized;
          request.response.write(
            '{"error":{"type":"authentication_error",'
            '"code":"invalid_credential","message":"fixture rejection"}}',
          );
          await request.response.close();
        });

        await expectLater(
          _perform(operation, UhpService(fixture.client), fixture.profile()),
          throwsA(_appError(_keyMessage)),
        );
        expect(fixture.requests.map((request) => request.uri.toString()), [
          _path(operation),
        ]);
        if (operation == _Operation.sse) {
          expect(jsonDecode(fixture.requests.single.body)['stream'], isTrue);
        }
      },
    );

    const unrelatedError =
        '{"error":{"type":"permission_denied","code":"invalid_credential"}}';
    const plainError = 'fixture proxy denied access';
    final longError = List.filled(400, 'x').join();
    final malformedError = '{"error":$longError';
    final genericBodies = {
      'unrelated JSON error': (unrelatedError, unrelatedError),
      'malformed JSON': (malformedError, malformedError),
      'plain text': (plainError, plainError),
      'long JSON error': (jsonEncode({'error': longError}), longError),
      'long JSON detail': (jsonEncode({'detail': longError}), longError),
    };
    for (final entry in genericBodies.entries) {
      test(
        '${operation.name} keeps ${entry.key} 401 generic and bounded',
        () async {
          final fixture = await _ApiServer.start((request) async {
            request.response.statusCode = HttpStatus.unauthorized;
            request.response.write(entry.value.$1);
            await request.response.close();
          });
          final diagnostic = entry.value.$2;
          final excerpt = diagnostic.length > 280
              ? '${diagnostic.substring(0, 280)}…'
              : diagnostic;

          await expectLater(
            _perform(operation, UhpService(fixture.client), fixture.profile()),
            throwsA(
              isA<ApiException>()
                  .having((error) => error.statusCode, 'status', 401)
                  .having((error) => error.body, 'body excerpt', excerpt),
            ),
          );
          expect(fixture.requests.map((request) => request.uri.toString()), [
            _path(operation),
          ]);
        },
      );
    }
  }

  test(
    'stopping authenticated SSE preserves partial output and client usability',
    () async {
      final partialReceived = Completer<void>();
      final fixture = await _ApiServer.start((request) async {
        if (request.uri.path != '/api/harness/v1/responses') {
          await _success(request);
          return;
        }
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
        );
        request.response.bufferOutput = false;
        request.response.write(
          'data: {"type":"response.output_text.delta","delta":"Partial"}\n\n',
        );
        await request.response.flush();
        // Keep the response open until the turn aborts or fixture teardown.
      });
      final service = UhpService(fixture.client);
      final profile = fixture.profile();
      final turn = service.startTurn(profile, _draft);
      final pending = turn.run(
        onProgress: (progress) {
          if (progress.text == 'Partial' && !partialReceived.isCompleted) {
            partialReceived.complete();
          }
        },
      );
      await partialReceived.future;
      await turn.stop(TurnStatus.cancelled);
      final result = await pending;
      expect(result.status, TurnStatus.cancelled);
      expect(result.output, 'Partial');
      expect(turn.finished, isTrue);

      await _perform(_Operation.rest, service, profile);
      expect(fixture.requests.map((request) => request.uri.toString()), [
        '/api/harness/v1/responses',
        '/api/harness/v1/harnesses',
      ]);
      expect(fixture.requests.first.authorization, 'Bearer fixture-api-key');
    },
  );
}
