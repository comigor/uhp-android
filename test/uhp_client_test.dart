import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:uhp_android/main.dart';

void main() {
  test('extracts assistant output text in order', () {
    final payload = <String, dynamic>{
      'output': <Map<String, dynamic>>[
        <String, dynamic>{
          'role': 'assistant',
          'content': <Map<String, String>>[
            <String, String>{'text': 'Hello'},
            <String, String>{'text': 'world'},
          ],
        },
        <String, dynamic>{
          'role': 'tool',
          'content': <Map<String, String>>[
            <String, String>{'text': 'ignore me'},
          ],
        },
        <String, dynamic>{
          'role': 'assistant',
          'content': <Map<String, String>>[
            <String, String>{'text': 'again'},
          ],
        },
      ],
    };

    expect(extractAssistantText(payload), 'Hello\nworld\nagain');
  });

  test('injects pangolin headers and console cookie', () {
    final pangolinHeaders = buildAuthHeaders(
      const ServerConfig(
        name: 'demo',
        baseUrl: 'https://example.test',
        authMode: AuthMode.pangolin,
        accessTokenId: 'token-id',
        accessToken: 'token-value',
      ),
    );
    expect(pangolinHeaders['P-Access-Token-Id'], 'token-id');
    expect(pangolinHeaders['P-Access-Token'], 'token-value');
    expect(pangolinHeaders.containsKey('Cookie'), isFalse);

    final consoleHeaders = buildAuthHeaders(
      const ServerConfig(
        name: 'demo',
        baseUrl: 'https://example.test',
        authMode: AuthMode.console,
        cookie: 'session=abc123',
      ),
    );
    expect(consoleHeaders['Cookie'], 'session=abc123');
  });

  test('builds continuation request body with previous response id', () {
    final body = buildResponseRequestBody(
      const ResponseDraft(
        input: 'continue this',
        harnessId: 'harness-1',
        previousResponseId: 'resp-1',
      ),
    );

    expect(body, <String, dynamic>{
      'input': 'continue this',
      'stream': false,
      'metadata': <String, dynamic>{'harness_id': 'harness-1'},
      'previous_response_id': 'resp-1',
    });
  });

  test('captures cookie from console login', () async {
    final service = UhpService(
      MockClient((request) async {
        expect(
          request.url.toString(),
          'https://example.test/api/selfhost/login',
        );
        expect(request.method, 'POST');
        expect(jsonDecode(request.body), <String, dynamic>{
          'username': 'igor',
          'password': 'secret',
        });
        return http.Response(
          '{}',
          200,
          headers: <String, String>{
            'set-cookie': 'session=abc123; Path=/; HttpOnly',
          },
        );
      }),
    );

    final updated = await service.login(
      const ServerConfig(
        name: 'demo',
        baseUrl: 'https://example.test/',
        authMode: AuthMode.console,
        username: 'igor',
        password: 'secret',
      ),
    );

    expect(updated.cookie, 'session=abc123');
  });
}
