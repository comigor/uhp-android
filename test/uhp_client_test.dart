import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:uhp_android/main.dart';

void main() {
  test('extracts assistant text from output messages', () {
    final json = {
      'output': [
        {
          'role': 'assistant',
          'content': [
            {'text': 'Hello'},
            {'text': ' world'},
          ],
        },
        {
          'role': 'tool',
          'content': [
            {'text': 'ignore'},
          ],
        },
      ],
    };

    expect(extractAssistantText(json), 'Hello\n world');
  });

  test('injects pangolin headers and cookie auth', () async {
    final pangolin = ApiClient(
      const ServerConfig(
        name: 's',
        baseUrl: 'https://example.test',
        authMode: AuthMode.pangolin,
        accessTokenId: 'token-id',
        accessToken: 'token',
      ),
      client: MockClient((request) async {
        expect(request.headers['P-Access-Token-Id'], 'token-id');
        expect(request.headers['P-Access-Token'], 'token');
        return http.Response(jsonEncode({'data': []}), 200);
      }),
    );
    await pangolin.fetchHarnesses();

    final cookie = ApiClient(
      const ServerConfig(
        name: 's',
        baseUrl: 'https://example.test',
        authMode: AuthMode.console,
        cookie: 'session=abc',
      ),
      client: MockClient((request) async {
        expect(request.headers['Cookie'], 'session=abc');
        return http.Response(jsonEncode({'data': []}), 200);
      }),
    );
    await cookie.fetchHarnesses();
  });

  test('builds continuation request bodies', () {
    final body = buildContinuationBody(input: 'continue', previousResponseId: 'resp-1', harnessId: 'h-1');
    expect(body, {
      'input': 'continue',
      'previous_response_id': 'resp-1',
      'metadata': {'harness_id': 'h-1'},
    });
  });
}
