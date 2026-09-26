import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uhp_android/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'malformed and stale server JSON is discarded without throwing',
    () async {
      for (final invalid in ['{broken', '[{"name":"legacy"}]']) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(ServerStore.key, invalid);
        final store = ServerStore(SharedPreferences.getInstance);
        expect(await store.load(), isEmpty);
        expect(prefs.containsKey(ServerStore.key), isFalse);
      }
    },
  );

  test(
    'legacy profiles require a key and discard obsolete fields on save',
    () async {
      final legacy = [
        for (final modeField in ['authMode', 'mode'])
          for (final mode in ['pangolin', 'console'])
            {
              'id': '$modeField-$mode',
              'name': 'Legacy',
              'baseUrl': 'https://example.test',
              modeField: mode,
              'accessTokenId': 'legacy-edge-id',
              'accessToken': 'legacy-edge-token',
              // Obsolete fields must be ignored even when their types are invalid.
              'username': 42,
              'password': ['obsolete'],
              'cookie': {'obsolete': true},
              'testResult': 'Previously connected',
            },
        {
          'id': 'layered',
          'baseUrl': 'https://example.test',
          'accessTokenId': 'legacy-edge-id',
          'accessToken': 'legacy-edge-token',
          'username': 'obsolete',
          'password': 'obsolete',
        },
      ];
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(ServerStore.key, jsonEncode(legacy));
      final store = ServerStore(SharedPreferences.getInstance);
      final profiles = await store.load();
      expect(
        profiles.map((profile) => profile.id),
        legacy.map((json) => json['id']),
      );
      for (final profile in profiles) {
        expect(profile.apiKey, isNull);
        expect(profile.hasApiKey, isFalse);
        expect(() => buildAuthHeaders(profile), throwsA(isA<AppError>()));
        final edgeEnabled = !profile.id.endsWith('console');
        expect(profile.hasPangolin, edgeEnabled);
        expect(profile.accessTokenId, edgeEnabled ? 'legacy-edge-id' : isNull);
        expect(profile.accessToken, edgeEnabled ? 'legacy-edge-token' : isNull);
      }
      await store.save(profiles);
      final saved = jsonDecode(prefs.getString(ServerStore.key)!) as List;
      for (final profile in saved.cast<Map<String, dynamic>>()) {
        expect(
          profile.keys,
          isNot(
            anyElement(
              isIn(['authMode', 'mode', 'username', 'password', 'cookie']),
            ),
          ),
        );
      }
      expect(
        (await store.load()).map((profile) => profile.id),
        profiles.map((profile) => profile.id),
      );
    },
  );

  test(
    'queued profile edits, test results, and deletion survive reload',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(serversProvider.future);
      final controller = container.read(serversProvider.notifier);
      const server = ServerConfig(
        id: 'stable-id',
        name: 'Before',
        baseUrl: 'https://example.test',
        apiKey: 'test-api-key',
      );
      await controller.add(server);
      final edits = [
        controller.updateProfile(server.copyWith(name: 'After')),
        controller.setTestResult(server.id, '2 harnesses'),
      ];
      await Future.wait(edits);
      final store = ServerStore(SharedPreferences.getInstance);
      final loaded = (await store.load()).single;
      expect(loaded.id, 'stable-id');
      expect(loaded.name, 'After');
      expect(loaded.testResult, '2 harnesses');
      expect(buildAuthHeaders(loaded).containsKey('Cookie'), isFalse);
      expect(loaded.toJson().containsKey('cookie'), isFalse);
      await controller.delete(server.id);
      expect(await store.load(), isEmpty);
    },
  );

  test('restored continuation uses snapshot, not current selections; deleted server blocks it', () async {
    final documents = await Directory.systemTemp.createTemp('uhp-context-');
    addTearDown(() => documents.delete(recursive: true));
    const server = ServerConfig(
      id: 'original',
      name: 'Original',
      baseUrl: 'https://original.test',
      apiKey: 'original-api-key',
      accessTokenId: 'id',
      accessToken: 'original-token',
    );
    const harness = Harness(
      id: 'original-harness',
      name: 'Original harness',
      baseLabel: '',
      defaultModel: 'default',
    );
    const record = ResponseRecord(
      prompt: 'Start',
      output: 'Answer',
      responseId: 'persisted-response',
      sessionId: 'session',
    );
    final thread = ConversationThread.start(
      server: server,
      harness: harness,
      prompt: record.prompt,
      record: record,
    );
    final store = ThreadStore(() async => documents);
    await store.save(thread);
    final profiles = ServerStore(SharedPreferences.getInstance);
    await profiles.save([server]);
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      expect(request.url.host, 'original.test');
      expect(request.headers['P-Access-Token'], 'original-token');
      expect(request.headers['Authorization'], 'Bearer original-api-key');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['previous_response_id'], 'persisted-response');
      expect(body['metadata'], {'harness_id': 'original-harness'});
      return http.Response(
        jsonEncode({
          'id': 'continued-response',
          'output': [
            {
              'role': 'assistant',
              'content': [
                {'text': 'Continued answer'},
              ],
            },
          ],
        }),
        200,
      );
    });
    addTearDown(client.close);
    final restartedStore = ThreadStore(() async => documents);
    final container = ProviderContainer(
      overrides: [
        threadStoreProvider.overrideWithValue(restartedStore),
        httpClientProvider.overrideWithValue(client),
      ],
    );
    addTearDown(container.dispose);
    await container.read(serversProvider.future);
    container.read(threadProvider.notifier).state = await restartedStore.read(
      thread.id,
    );
    container.read(selectedServerProvider.notifier).state = const ServerConfig(
      id: 'other',
      name: 'Other',
      baseUrl: 'https://other.test',
    );
    container.read(selectedHarnessProvider.notifier).state = const Harness(
      id: 'other-harness',
      name: 'Other',
      baseLabel: '',
      defaultModel: '',
    );
    await container.read(taskRunnerProvider).submit('Continue');
    final saved = (await ThreadStore(() async => documents).read(thread.id))!;
    expect(saved.lastResponseId, 'continued-response');
    expect(saved.messages.map((m) => m.text), [
      'Start',
      'Answer',
      'Continue',
      'Continued answer',
    ]);
    await container.read(serversProvider.notifier).delete(server.id);
    await expectLater(
      container.read(taskRunnerProvider).submit('Blocked'),
      throwsA(
        isA<AppError>().having(
          (error) => error.message,
          'message',
          contains('deleted'),
        ),
      ),
    );
    expect(requests, 1);
  });
}
