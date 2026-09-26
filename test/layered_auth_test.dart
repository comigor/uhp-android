import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:uhp_android/main.dart';

class AuthClient extends http.BaseClient {
  AuthClient(this.respond);

  final Future<http.StreamedResponse> Function(http.Request) respond;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      respond(request as http.Request);
}

http.StreamedResponse reply(
  String body,
  int status, {
  Map<String, String> headers = const {},
}) => http.StreamedResponse(
  Stream.value(utf8.encode(body)),
  status,
  headers: headers,
);

http.StreamedResponse loggedIn(String cookie) =>
    reply('{}', 200, headers: {'set-cookie': '$cookie; Path=/; HttpOnly'});

const combined = ServerConfig(
  id: 'combined',
  name: 'Combined',
  baseUrl: 'https://example.test',
  accessTokenId: 'edge-id',
  accessToken: 'edge-secret',
  username: 'alice',
  password: 'console-secret',
);

Matcher authFailure(int status, Matcher message) => isA<AuthException>()
    .having((error) => error.statusCode, 'status', status)
    .having(
      (error) => error.message.toLowerCase(),
      'actionable category',
      message,
    );

void main() {
  test(
    'headers-only 401 asks for console credentials without a login attempt',
    () async {
      var requests = 0;
      final service = UhpService(
        AuthClient((request) async {
          requests++;
          expect(request.url.path, '/api/harness/v1/harnesses');
          expect(request.headers['P-Access-Token-Id'], 'edge-id');
          expect(request.headers['P-Access-Token'], 'edge-secret');
          expect(request.headers.containsKey('Cookie'), isFalse);
          return reply('unauthorized', 401);
        }),
      );

      await expectLater(
        service.fetchHarnesses(
          const ServerConfig(
            id: 'edge-only',
            name: 'Edge only',
            baseUrl: 'https://example.test',
            accessTokenId: 'edge-id',
            accessToken: 'edge-secret',
          ),
        ),
        throwsA(
          authFailure(
            401,
            allOf(
              contains('console'),
              anyOf(contains('credential'), contains('username')),
            ),
          ),
        ),
      );
      expect(requests, 1);
    },
  );

  test('combined login precedes API and sends both layers without persisting cookie', () async {
    final paths = <String>[];
    final service = UhpService(
      AuthClient((request) async {
        paths.add(request.url.path);
        expect(request.followRedirects, isFalse);
        expect(request.headers['P-Access-Token-Id'], 'edge-id');
        expect(request.headers['P-Access-Token'], 'edge-secret');
        if (request.url.path == '/api/selfhost/login') {
          expect(request.method, 'POST');
          expect(jsonDecode(request.body), {
            'username': 'alice',
            'password': 'console-secret',
          });
          return loggedIn('session=combined');
        }
        expect(request.headers['Cookie'], 'session=combined');
        return reply('{"data":[{"id":"private-harness"}]}', 200);
      }),
    );

    expect(await service.testConnection(combined), contains('1'));
    expect(paths, ['/api/selfhost/login', '/api/harness/v1/harnesses']);
    final restored = ServerConfig.fromJson(combined.toJson());
    expect(restored.hasPangolin, isTrue);
    expect(restored.hasConsoleCredentials, isTrue);
    expect(buildAuthHeaders(restored).containsKey('Cookie'), isFalse);
    expect(combined.toJson().containsKey('cookie'), isFalse);
  });

  test('cached cookie is reused and one rejected request refreshes and retries once', () async {
    var logins = 0;
    var apiCalls = 0;
    final cookies = <String?>[];
    final service = UhpService(
      AuthClient((request) async {
        if (request.url.path == '/api/selfhost/login') {
          logins++;
          return loggedIn('session=$logins');
        }
        apiCalls++;
        cookies.add(request.headers['Cookie']);
        if (apiCalls == 3) return reply('expired', 401);
        return reply('{"data":[{"id":"available"}]}', 200);
      }),
    );

    await service.fetchHarnesses(combined);
    await service.fetchHarnesses(combined);
    expect(logins, 1);
    expect((await service.fetchHarnesses(combined)).single.id, 'available');
    expect(logins, 2);
    expect(cookies, ['session=1', 'session=1', 'session=1', 'session=2']);
    expect(apiCalls, 4);
  });

  test(
    'rejected refreshed cookie stops after one retry with after-login category',
    () async {
      var logins = 0;
      var apiCalls = 0;
      final service = UhpService(
        AuthClient((request) async {
          if (request.url.path == '/api/selfhost/login') {
            logins++;
            return loggedIn('session=$logins');
          }
          apiCalls++;
          return reply(
            apiCalls == 1 ? '{"data":[]}' : 'still unauthorized',
            apiCalls == 1 ? 200 : 401,
          );
        }),
      );
      await service.fetchHarnesses(combined);

      await expectLater(
        service.fetchHarnesses(combined),
        throwsA(authFailure(401, allOf(contains('after'), contains('login')))),
      );
      expect(logins, 2);
      expect(apiCalls, 3);
    },
  );

  test('cookies are isolated by profile, URL and each credential', () async {
    var logins = 0;
    String? expectedCookie;
    final service = UhpService(
      AuthClient((request) async {
        if (request.url.path == '/api/selfhost/login') {
          logins++;
          expectedCookie = 'session=$logins';
          return loggedIn(expectedCookie!);
        }
        expect(request.headers['Cookie'], expectedCookie);
        return reply('{"data":[]}', 200);
      }),
    );
    final profiles = <ServerConfig>[
      combined,
      for (final field in [
        'id',
        'baseUrl',
        'accessTokenId',
        'accessToken',
        'username',
        'password',
      ])
        ServerConfig.fromJson({
          ...combined.toJson(),
          field: field == 'baseUrl' ? 'https://other.test' : 'changed-$field',
        }),
    ];
    for (var i = 0; i < profiles.length; i++) {
      await service.fetchHarnesses(profiles[i]);
      expect(logins, i + 1);
    }
    expectedCookie = 'session=1';
    await service.fetchHarnesses(combined);
    expect(logins, profiles.length);
  });

  test(
    '302 at API or login is classified as edge rejection and never followed',
    () async {
      for (final profile in [
        const ServerConfig(
          id: 'edge-only',
          name: 'Edge only',
          baseUrl: 'https://example.test',
          accessTokenId: 'edge-id',
          accessToken: 'edge-secret',
        ),
        combined,
      ]) {
        var requests = 0;
        final service = UhpService(
          AuthClient((request) async {
            requests++;
            expect(request.followRedirects, isFalse);
            return reply(
              '',
              302,
              headers: {'location': 'https://edge.test/login'},
            );
          }),
        );
        await expectLater(
          service.fetchHarnesses(profile),
          throwsA(authFailure(302, contains('pangolin'))),
        );
        expect(requests, 1);
      }
    },
  );

  test('streaming and cancel share cookie cache and retain turn and session context', () async {
    var logins = 0;
    var cancellations = 0;
    final service = UhpService(
      AuthClient((request) async {
        expect(request.followRedirects, isFalse);
        expect(request.headers['P-Access-Token-Id'], 'edge-id');
        expect(request.headers['P-Access-Token'], 'edge-secret');
        if (request.url.path == '/api/selfhost/login') {
          logins++;
          return loggedIn('session=$logins');
        }
        if (request.url.path.endsWith('/cancel')) {
          cancellations++;
          expect(
            request.url.toString(),
            'https://example.test/v1/sessions/session%2Fa%20b/cancel',
          );
          expect(request.method, 'POST');
          expect(jsonDecode(request.body), isEmpty);
          expect(request.headers['Cookie'], 'session=$cancellations');
          return reply('', cancellations == 1 ? 401 : 204);
        }
        expect(request.url.path, '/api/harness/v1/responses');
        expect(request.headers['Cookie'], 'session=1');
        expect(jsonDecode(request.body), {
          'input': 'Continue',
          'stream': true,
          'metadata': {'harness_id': 'harness'},
          'previous_response_id': 'previous',
        });
        return reply(
          'data: ${jsonEncode({
            'type': 'response.completed',
            'response': {
              'id': 'next',
              'output': [
                {
                  'role': 'assistant',
                  'content': [
                    {'text': 'Answer'},
                  ],
                },
              ],
            },
          })}\n\n',
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }),
    );

    final result = await service
        .startTurn(
          combined,
          const ResponseDraft(
            input: 'Continue',
            harnessId: 'harness',
            previousResponseId: 'previous',
          ),
        )
        .run(onProgress: (_) {});
    expect(result.output, 'Answer');
    expect(result.responseId, 'next');
    expect(logins, 1);
    await service.cancelSession(combined, 'session/a b');
    expect(cancellations, 2);
    expect(logins, 2);
  });

  test(
    'streaming authentication failure is not retried as non-streaming fallback',
    () async {
      var logins = 0;
      var apiCalls = 0;
      final service = UhpService(
        AuthClient((request) async {
          if (request.url.path == '/api/selfhost/login') {
            logins++;
            return loggedIn('session=$logins');
          }
          apiCalls++;
          expect(jsonDecode(request.body)['stream'], isTrue);
          return reply('unauthorized', 401);
        }),
      );

      await expectLater(
        service
            .startTurn(
              combined,
              const ResponseDraft(input: 'Question', harnessId: 'harness'),
            )
            .run(onProgress: (_) {}),
        throwsA(authFailure(401, allOf(contains('after'), contains('login')))),
      );
      expect(logins, 2);
      expect(apiCalls, 2);
    },
  );

  test('stopping a turn during console login aborts login and never submits the turn', () async {
    final started = Completer<void>();
    final aborted = Completer<void>();
    var requests = 0;
    final service = UhpService(
      AuthClient((request) async {
        requests++;
        expect(request.url.path, '/api/selfhost/login');
        final abort = (request as http.AbortableRequest).abortTrigger;
        expect(abort, isNotNull);
        started.complete();
        await abort;
        aborted.complete();
        throw http.RequestAbortedException(request.url);
      }),
    );
    final turn = service.startTurn(
      combined,
      const ResponseDraft(input: 'Never submit', harnessId: 'harness'),
    );
    final pending = turn.run(onProgress: (_) {});
    await started.future;
    await turn.stop(TurnStatus.cancelled);
    expect((await pending).status, TurnStatus.cancelled);
    await aborted.future;
    expect(requests, 1);
  });

  test('legacy modes drop inactive fields and cookies, new profiles preserve both layers', () {
    for (final key in ['authMode', 'mode']) {
      for (final mode in ['pangolin', 'console']) {
        final migrated = ServerConfig.fromJson({
          ...combined.toJson(),
          key: mode,
          'cookie': 'session=legacy',
        });
        expect(migrated.hasPangolin, mode == 'pangolin');
        expect(migrated.hasConsoleCredentials, mode == 'console');
        expect(migrated.accessTokenId, mode == 'pangolin' ? 'edge-id' : isNull);
        expect(
          migrated.accessToken,
          mode == 'pangolin' ? 'edge-secret' : isNull,
        );
        expect(migrated.username, mode == 'console' ? 'alice' : isNull);
        expect(
          migrated.password,
          mode == 'console' ? 'console-secret' : isNull,
        );
        expect(buildAuthHeaders(migrated).containsKey('Cookie'), isFalse);
        expect(
          migrated.toJson().keys,
          isNot(anyElement(isIn(['authMode', 'mode', 'cookie']))),
        );
      }
    }
    final restored = ServerConfig.fromJson(
      jsonDecode(jsonEncode(combined.toJson())),
    );
    expect(restored.hasPangolin, isTrue);
    expect(restored.hasConsoleCredentials, isTrue);
    expect(restored.accessToken, combined.accessToken);
    expect(restored.password, combined.password);
  });

  test('missing optional fields and incomplete pairs do not activate authentication', () {
    final minimal = ServerConfig.fromJson({'id': 'minimal'});
    expect(minimal.hasPangolin, isFalse);
    expect(minimal.hasConsoleCredentials, isFalse);
    expect(buildAuthHeaders(minimal), {'Content-Type': 'application/json'});
    expect(
      () => ServerConfig.fromJson({'name': 'Missing identity'}),
      throwsA(anyOf(isA<FormatException>(), isA<TypeError>())),
    );
    for (final incomplete in [
      const ServerConfig(
        name: 'Partial',
        baseUrl: 'https://example.test',
        accessTokenId: 'id',
        username: 'alice',
      ),
      const ServerConfig(
        name: 'Partial',
        baseUrl: 'https://example.test',
        accessToken: 'secret',
        password: 'secret',
      ),
      const ServerConfig(
        name: 'Whitespace',
        baseUrl: 'https://example.test',
        accessTokenId: ' ',
        accessToken: 'secret',
        username: ' ',
        password: 'secret',
      ),
    ]) {
      expect(incomplete.hasPangolin, isFalse);
      expect(incomplete.hasConsoleCredentials, isFalse);
      expect(buildAuthHeaders(incomplete), {
        'Content-Type': 'application/json',
      });
    }
  });
}
