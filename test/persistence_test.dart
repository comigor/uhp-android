import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uhp_android/main.dart';

void main() {
  test('server JSON roundtrip preserves identity and authentication', () {
    const profiles = <ServerConfig>[
      ServerConfig(
        id: 'pangolin-server',
        name: 'Pangolin server',
        baseUrl: 'https://pangolin.example.test',
        authMode: AuthMode.pangolin,
        accessTokenId: 'machine-id',
        accessToken: 'machine-secret',
      ),
      ServerConfig(
        id: 'console-server',
        name: 'Console server',
        baseUrl: 'https://console.example.test',
        authMode: AuthMode.console,
        username: 'alice',
        password: 'login-secret',
        cookie: 'session=saved-cookie',
      ),
    ];

    for (final profile in profiles) {
      final restored = ServerConfig.fromJson(
        jsonDecode(jsonEncode(profile.toJson())) as Map<String, dynamic>,
      );

      expect(restored.id, profile.id);
      expect(restored.name, profile.name);
      expect(restored.baseUrl, profile.baseUrl);
      expect(restored.authMode, profile.authMode);
      expect(restored.username, profile.username);
      expect(restored.password, profile.password);
      expect(buildAuthHeaders(restored), buildAuthHeaders(profile));
    }
  });

  group('thread persistence', () {
    late Directory documents;
    late ThreadStore store;
    const server = ServerConfig(
      id: 'server-1',
      name: 'Saved server',
      baseUrl: 'https://example.test',
      authMode: AuthMode.console,
      username: 'alice',
      password: 'saved-password',
      cookie: 'session=thread-cookie',
    );
    const harness = Harness(
      id: 'harness-1',
      name: 'Saved harness',
      baseLabel: 'Default',
      defaultModel: 'server-default',
    );
    const first = ResponseRecord(
      prompt: 'First question',
      output: 'First answer',
      responseId: 'response-1',
      sessionId: 'session-1',
    );
    const second = ResponseRecord(
      prompt: 'Follow-up question',
      output: 'Follow-up answer',
      responseId: 'response-2',
      sessionId: 'session-1',
    );

    setUp(() async {
      documents = await Directory.systemTemp.createTemp('uhp-persistence-');
      store = ThreadStore(() async => documents);
    });

    tearDown(() async {
      await documents.delete(recursive: true);
    });

    test(
      'fresh stores restore turns, snapshots, and continuation ID',
      () async {
        final thread = ConversationThread.start(
          server: server,
          harness: harness,
          prompt: first.prompt,
          record: first,
        );
        await store.save(thread);

        final reopened = ThreadStore(() async => documents);
        final index = await reopened.loadIndex();
        expect(index.map((entry) => entry.id), <String>[thread.id]);
        expect(index.single.serverId, server.id);
        expect(index.single.harnessId, harness.id);

        final loaded = (await reopened.read(thread.id))!;
        expect(loaded.server.id, server.id);
        expect(loaded.server.password, server.password);
        expect(buildAuthHeaders(loaded.server), buildAuthHeaders(server));
        expect(loaded.harnessId, harness.id);
        expect(loaded.harnessName, harness.name);
        expect(loaded.messages.map((message) => message.text), <String>[
          first.prompt,
          first.output,
        ]);
        expect(loaded.lastResponseId, first.responseId);

        await reopened.save(loaded.appendTurn(second.prompt, second));

        final restarted = ThreadStore(() async => documents);
        final continued = (await restarted.read(thread.id))!;
        expect(continued.lastResponseId, second.responseId);
        expect(continued.messages.map((message) => message.text), <String>[
          first.prompt,
          first.output,
          second.prompt,
          second.output,
        ]);
        expect(
          buildResponseRequestBody(
            ResponseDraft(
              input: 'Third question',
              harnessId: continued.harnessId,
              previousResponseId: continued.lastResponseId,
            ),
          )['previous_response_id'],
          second.responseId,
        );
        expect((await restarted.loadIndex()).map((entry) => entry.id), <String>[
          thread.id,
        ]);
      },
    );

    test(
      'deletion removes the thread file and persisted index entry',
      () async {
        final removed = ConversationThread.start(
          server: server,
          harness: harness,
          prompt: first.prompt,
          record: first,
        );
        final retained = ConversationThread.start(
          server: server,
          harness: harness,
          prompt: second.prompt,
          record: second,
        );
        await store.save(removed);
        await store.save(retained);

        final threadFile = File('${documents.path}/threads/${removed.id}.json');
        expect(await threadFile.exists(), isTrue);
        await store.delete(removed.id);
        expect(await threadFile.exists(), isFalse);

        final reopened = ThreadStore(() async => documents);
        expect(await reopened.read(removed.id), isNull);
        expect((await reopened.loadIndex()).map((entry) => entry.id), <String>[
          retained.id,
        ]);
        expect(
          (await reopened.read(retained.id))!.lastResponseId,
          second.responseId,
        );
      },
    );

    test('malformed index JSON recovers as an empty history', () async {
      final directory = Directory('${documents.path}/threads');
      await directory.create(recursive: true);
      await File('${directory.path}/index.json').writeAsString('{broken');

      expect(await store.loadIndex(), isEmpty);
    });

    test('malformed thread JSON does not prevent loading the index', () async {
      final thread = ConversationThread.start(
        server: server,
        harness: harness,
        prompt: first.prompt,
        record: first,
      );
      await store.save(thread);
      await File('${documents.path}/threads/${thread.id}.json')
          .writeAsString('{broken');

      final reopened = ThreadStore(() async => documents);
      expect((await reopened.loadIndex()).map((entry) => entry.id), <String>[
        thread.id,
      ]);
      expect(await reopened.read(thread.id), isNull);
    });
  });
}
