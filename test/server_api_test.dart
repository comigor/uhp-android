import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:uhp_android/main.dart';

const _server = ServerConfig(
  id: 'server',
  name: 'Server',
  baseUrl: 'https://example.test/',
  apiKey: ' api-key ',
  accessTokenId: ' edge-id ',
  accessToken: ' edge-token ',
);

http.Response _json(Object? value, [int status = 200]) =>
    http.Response(jsonEncode(value), status);

void main() {
  test(
    'session cards retain known fields and pass opaque cursors and filters',
    () async {
      final requests = <http.Request>[];
      const cursor = 'next+/=& ?';
      final service = UhpService(
        MockClient((request) async {
          requests.add(request);
          if (request.url.queryParameters.containsKey('cursor')) {
            return _json({'sessions': [], 'next_cursor': null});
          }
          return _json({
            'sessions': [
              {
                'id': 'not-the-session-key',
                'session_id': 'session-1',
                'title': 'A conversation',
                'model': 'model-1',
                'harness_id': 'harness/one',
                'status': 'running',
                'last_response_id': 'response-1',
                'updated_at': '2026-08-31T12:34:56Z',
                'future_field': {'opaque': true},
              },
              {
                'sessionId': 'session-2',
                'title': {'unknown': 'shape'},
                'harnessId': 'harness/one',
                'lastResponseId': 'response-2',
                'updatedAt': 'not a date',
                'status': 'completed',
              },
              null,
              42,
              {'unexpected': 'without identity'},
            ],
            'next_cursor': cursor,
            'future_metadata': true,
          });
        }),
      );

      final page = await service.fetchSessions(
        _server,
        harnessId: 'harness/one',
      );
      expect(page.sessions.map((session) => session.id), [
        'session-1',
        'session-2',
      ]);
      final card = page.sessions.first;
      expect(card.title, 'A conversation');
      expect(card.model, 'model-1');
      expect(card.harnessId, 'harness/one');
      expect(card.status, 'running');
      expect(card.isRunning, isTrue);
      expect(card.lastResponseId, 'response-1');
      expect(card.updatedAt, DateTime.utc(2026, 8, 31, 12, 34, 56));
      expect(page.sessions.last.title, isEmpty);
      expect(page.sessions.last.updatedAt, isNull);
      expect(page.sessions.last.isRunning, isFalse);
      expect(page.cursor, cursor);
      final next = await service.fetchSessions(
        _server,
        cursor: page.cursor,
        harnessId: 'harness/one',
      );
      expect(next.sessions, isEmpty);
      expect(next.cursor, isNull);
      expect(requests.first.method, 'GET');
      expect(requests.first.url.path, '/api/harness/v1/sessions');
      expect(requests.first.url.queryParameters, {
        'limit': '20',
        'harness': 'harness/one',
      });
      expect(requests.last.url.queryParameters, {
        'limit': '20',
        'harness': 'harness/one',
        'cursor': cursor,
      });
    },
  );

  test(
    'unfiltered session data envelope omits optional query parameters',
    () async {
      final service = UhpService(
        MockClient((request) async {
          expect(request.url.queryParameters, {'limit': '20'});
          return _json({
            'data': [
              {
                'id': 'session',
                'status': 'in_progress',
                'created_at': '2026-08-30T01:02:03Z',
              },
            ],
            'cursor': 'opaque',
          });
        }),
      );
      final page = await service.fetchSessions(_server);
      expect(page.sessions.single.isRunning, isTrue);
      expect(
        page.sessions.single.updatedAt,
        DateTime.utc(2026, 8, 30, 1, 2, 3),
      );
      expect(page.cursor, 'opaque');
    },
  );

  test('detail and heterogeneous turns encode session identity and ignore unknown data', () async {
    final paths = <String>[];
    final service = UhpService(
      MockClient((request) async {
        expect(request.method, 'GET');
        paths.add(request.url.toString());
        if (request.url.path.endsWith('/turns')) {
          return _json({
            'turns': [
              {'role': 'user', 'content': 'Hello'},
              {
                'role': 'assistant',
                'content': [
                  {'type': 'output_text', 'text': 'First'},
                  {'type': 'future_block', 'opaque': {}},
                  {'type': 'output_text', 'text': 'Second'},
                ],
              },
              {'role': 'tool', 'text': 'Tool result', 'unknown': true},
              {
                'input': 'Continue',
                'output': [
                  {
                    'content': [
                      {'text': 'Done'},
                    ],
                  },
                ],
              },
              {'role': 'future_role', 'text': 'Future role output'},
              {
                'future_only': [1, 2],
              },
              123,
              null,
            ],
            'future': true,
          });
        }
        return _json({
          'data': {
            'id': 'session/a b?x',
            'lastResponseId': 'latest',
            'status': 'in_progress',
            'metadata': {'harness_id': 'harness'},
            'future': [],
          },
        });
      }),
    );
    final detail = await service.fetchSession(_server, 'session/a b?x');
    expect(detail.id, 'session/a b?x');
    expect(detail.lastResponseId, 'latest');
    expect(detail.harnessId, 'harness');
    expect(detail.isRunning, isTrue);
    final turns = await service.fetchSessionTurns(_server, detail.id);
    expect(turns.map((turn) => (turn.role, turn.text)), [
      ('user', 'Hello'),
      ('assistant', 'First\nSecond'),
      ('tool', 'Tool result'),
      ('user', 'Continue'),
      ('assistant', 'Done'),
      ('future_role', 'Future role output'),
    ]);
    expect(paths, [
      'https://example.test/api/harness/v1/sessions/session%2Fa%20b%3Fx',
      'https://example.test/api/harness/v1/sessions/session%2Fa%20b%3Fx/turns',
    ]);
  });

  test('model catalogues accept lists and data/models envelopes', () async {
    final payloads = <Object>[
      [
        'model-1',
        {'id': 'model-2'},
        {'name': 'model-3'},
      ],
      {
        'data': [
          'model-1',
          {'id': 'model-2'},
          {'name': 'model-3'},
        ],
      },
      {
        'models': [
          'model-1',
          {'id': 'model-2'},
          {'name': 'model-3'},
          null,
          42,
          {},
          '',
        ],
      },
    ];
    for (final payload in payloads) {
      final service = UhpService(
        MockClient((request) async {
          expect(request.url.path, '/api/harness/v1/models');
          return _json(payload);
        }),
      );
      expect(await service.fetchModels(_server), [
        'model-1',
        'model-2',
        'model-3',
      ]);
    }
  });

  test('nonempty harness catalogue does not request global models', () async {
    final paths = <String>[];
    final service = UhpService(
      MockClient((request) async {
        paths.add(request.url.toString());
        return _json({
          'models': [
            {'id': 'harness-model'},
          ],
        });
      }),
    );
    expect(await service.fetchModels(_server, harnessId: 'h/a b'), [
      'harness-model',
    ]);
    expect(paths, [
      'https://example.test/api/harness/v1/harnesses/h%2Fa%20b/models',
    ]);
  });

  test(
    'only unsupported or empty harness catalogues fall back to global models',
    () async {
      for (final status in [200, 404, 405, 501]) {
        final paths = <String>[];
        final service = UhpService(
          MockClient((request) async {
            paths.add(request.url.path);
            if (request.url.path.startsWith('/api/harness/v1/harnesses/')) {
              return _json(
                status == 200 ? {'data': []} : {'error': 'unsupported'},
                status,
              );
            }
            return _json({
              'data': [
                {'id': 'global-model'},
              ],
            });
          }),
        );
        expect(await service.fetchModels(_server, harnessId: 'h'), [
          'global-model',
        ]);
        expect(paths, [
          '/api/harness/v1/harnesses/h/models',
          '/api/harness/v1/models',
        ]);
      }
    },
  );

  test(
    'model fallback never hides auth or arbitrary server failures',
    () async {
      for (final status in [302, 303, 307, 308, 400, 401, 403, 429, 500]) {
        final paths = <String>[];
        final service = UhpService(
          MockClient((request) async {
            paths.add(request.url.path);
            return _json({
              'error': status == 401
                  ? {'type': 'authentication_error'}
                  : 'rejected',
            }, status);
          }),
        );
        await expectLater(
          service.fetchModels(_server, harnessId: 'h'),
          throwsA(
            [302, 303, 307, 308, 401].contains(status)
                ? isA<AuthException>()
                : isA<ApiException>().having(
                    (error) => error.statusCode,
                    'status',
                    status,
                  ),
          ),
        );
        expect(paths, ['/api/harness/v1/harnesses/h/models']);
      }
    },
  );

  test('updating default model PUTs the full fetched harness without losing fields', () async {
    final original = <String, dynamic>{
      'id': 'h/a b',
      'name': 'Required harness name',
      'base': 'required-base',
      'defaultModel': 'old-model',
      'description': 'Keep this',
      'tools': [
        {
          'name': 'tool',
          'config': {
            'nested': [1, true, null],
          },
        },
      ],
      'provider': {
        'url': 'https://provider.test',
        'options': {'temperature': 0.4},
      },
      'data': {'custom': 'not an envelope'},
      'futureFlag': true,
    };
    for (final selectedModel in <String?>['new-model', null]) {
      final methods = <String>[];
      final service = UhpService(
        MockClient((request) async {
          methods.add(request.method);
          expect(
            request.url.toString(),
            'https://example.test/api/harness/v1/harnesses/h%2Fa%20b',
          );
          if (request.method == 'GET') {
            return _json(
              selectedModel == null ? {'harness': original} : original,
            );
          }
          final body = jsonDecode(request.body);
          expect(body, {...original, 'defaultModel': selectedModel});
          expect(body, isNot(contains('default_model')));
          return _json({'data': body});
        }),
      );
      final updated = await service.updateHarnessDefaultModel(
        _server,
        'h/a b',
        selectedModel,
      );
      expect(updated['defaultModel'], selectedModel);
      expect(updated['provider'], original['provider']);
      expect(methods, ['GET', 'PUT']);
    }
  });

  test('incomplete harness details never produce a partial PUT', () async {
    for (final detail in <Map<String, dynamic>>[
      {},
      {'id': 'h', 'name': 'Harness'},
      {'id': 'h', 'base': 'base'},
      {'id': 'h', 'name': 'Harness', 'base': null},
    ]) {
      final methods = <String>[];
      final service = UhpService(
        MockClient((request) async {
          methods.add(request.method);
          return _json(detail);
        }),
      );
      await expectLater(
        service.updateHarnessDefaultModel(_server, 'h', 'new'),
        throwsA(isA<AppError>()),
      );
      expect(methods, ['GET']);
    }
  });

  test(
    'default update requires an explicit matching value in the PUT response',
    () async {
      for (final response in [
        {'name': 'Harness', 'base': 'base', 'defaultModel': 'old'},
        {'name': 'Harness', 'base': 'base'},
      ]) {
        final service = UhpService(
          MockClient((request) async {
            if (request.method == 'GET') {
              return _json({
                'name': 'Harness',
                'base': 'base',
                'defaultModel': 'old',
              });
            }
            return _json(response);
          }),
        );
        await expectLater(
          service.updateHarnessDefaultModel(_server, 'h', 'new'),
          throwsA(isA<AppError>()),
        );
      }
    },
  );

  test(
    'every server API operation uses mounted paths and profile authentication',
    () async {
      final methods = <String>[];
      final service = UhpService(
        MockClient((request) async {
          methods.add('${request.method} ${request.url.path}');
          expect(request.url.path, startsWith('/api/harness/v1/'));
          expect(request.headers['Authorization'], 'Bearer api-key');
          expect(request.headers['P-Access-Token-Id'], 'edge-id');
          expect(request.headers['P-Access-Token'], 'edge-token');
          expect(request.followRedirects, isFalse);
          if (request.url.path == '/api/harness/v1/sessions') {
            return _json({'sessions': []});
          }
          if (request.url.path.endsWith('/turns')) return _json({'turns': []});
          if (request.url.path == '/api/harness/v1/sessions/s') {
            return _json({'id': 's'});
          }
          if (request.url.path.endsWith('/models')) return _json(['model']);
          return _json({
            'id': 'h',
            'name': 'Harness',
            'base': 'base',
            'defaultModel': 'model',
          });
        }),
      );
      await service.fetchSessions(_server);
      await service.fetchSession(_server, 's');
      await service.fetchSessionTurns(_server, 's');
      await service.fetchModels(_server);
      await service.fetchModels(_server, harnessId: 'h');
      await service.fetchHarnessDetail(_server, 'h');
      await service.updateHarnessDefaultModel(_server, 'h', 'model');
      expect(methods, [
        'GET /api/harness/v1/sessions',
        'GET /api/harness/v1/sessions/s',
        'GET /api/harness/v1/sessions/s/turns',
        'GET /api/harness/v1/models',
        'GET /api/harness/v1/harnesses/h/models',
        'GET /api/harness/v1/harnesses/h',
        'GET /api/harness/v1/harnesses/h',
        'PUT /api/harness/v1/harnesses/h',
      ]);
    },
  );
}
