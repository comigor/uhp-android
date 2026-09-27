import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uhp_android/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  ProviderContainer openPreferences() {
    final container = ProviderContainer(
      overrides: [
        appPreferencesStoreProvider.overrideWithValue(
          AppPreferencesStore(SharedPreferences.getInstance),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('server, per-server harnesses, and filter survive reopening', () async {
    final container = openPreferences();
    await container.read(appPreferencesProvider.future);
    final controller = container.read(appPreferencesProvider.notifier);
    await controller.selectServer('server-a');
    await controller.selectHarness('server-a', 'harness-a');
    await controller.setFeedFilter('on-device');
    await controller.selectServer('server-b');
    await controller.selectHarness('server-b', 'harness-b');

    final reopened = openPreferences();
    final restored = await reopened.read(appPreferencesProvider.future);
    expect(restored.lastServerId, 'server-b');
    expect(restored.lastHarnessIds, {
      'server-a': 'harness-a',
      'server-b': 'harness-b',
    });
    expect(restored.feedFilter, 'on-device');

    final restarted = reopened.read(appPreferencesProvider.notifier);
    await restarted.selectServer('server-a');
    await restarted.setFeedFilter('harness:harness-a');
    final saved = await AppPreferencesStore(SharedPreferences.getInstance)
        .load();
    expect(saved.lastServerId, 'server-a');
    expect(saved.lastHarnessIds, restored.lastHarnessIds);
    expect(saved.feedFilter, 'harness:harness-a');
  });

  test('queued changes before loading preserve unrelated selections', () async {
    final store = AppPreferencesStore(SharedPreferences.getInstance);
    await store.save(
      AppPreferences(
        lastServerId: 'server-old',
        lastHarnessIds: {'server-old': 'harness-old'},
        feedFilter: 'on-device',
      ),
    );
    final container = openPreferences();
    final controller = container.read(appPreferencesProvider.notifier);
    await Future.wait([
      controller.selectServer('server-a'),
      controller.selectHarness('server-a', 'harness-first'),
      controller.setFeedFilter('harness:harness-next'),
      controller.selectServer('server-b'),
      controller.selectHarness('server-b', 'harness-b'),
      controller.selectHarness('server-a', 'harness-next'),
    ]);

    final restored = await store.load();
    expect(restored.lastServerId, 'server-b');
    expect(restored.lastHarnessIds, {
      'server-old': 'harness-old',
      'server-a': 'harness-next',
      'server-b': 'harness-b',
    });
    expect(restored.feedFilter, 'harness:harness-next');
  });

  test(
    'malformed preferences never change saved profiles or threads',
    () async {
      final documents = await Directory.systemTemp.createTemp('uhp-app-prefs-');
      addTearDown(() => documents.delete(recursive: true));
      const server = ServerConfig(
        id: 'saved-server',
        name: 'Saved server',
        baseUrl: 'https://example.test',
        apiKey: 'test-api-key',
      );
      final servers = ServerStore(SharedPreferences.getInstance);
      await servers.save([server]);
      final threads = ThreadStore(() async => documents);
      final thread = ConversationThread.start(
        server: server,
        harness: const Harness(
          id: 'saved-harness',
          name: 'Saved harness',
          baseLabel: 'Default',
          defaultModel: 'default-model',
        ),
        prompt: 'Saved question',
        record: const ResponseRecord(
          prompt: 'Saved question',
          output: 'Saved answer',
          responseId: 'saved-response',
          sessionId: 'saved-session',
        ),
      );
      await threads.save(thread);
      final prefs = await SharedPreferences.getInstance();
      final serverJson = prefs.getString(ServerStore.key);
      final store = AppPreferencesStore(SharedPreferences.getInstance);

      for (final invalid in ['{broken', '[]', 'null', '{"feedFilter": 42}']) {
        await prefs.setString(AppPreferencesStore.key, invalid);
        final restored = await store.load();
        expect(restored.lastServerId, isNull);
        expect(restored.lastHarnessIds, isEmpty);
        expect(restored.feedFilter, 'all');
        expect(prefs.getString(ServerStore.key), serverJson);
        expect((await servers.load()).single.toJson(), server.toJson());
        expect((await threads.read(thread.id))!.toJson(), thread.toJson());
        expect((await threads.loadIndex()).single.id, thread.id);
      }

      await prefs.setInt(AppPreferencesStore.key, 7);
      expect((await store.load()).feedFilter, 'all');
      final container = openPreferences();
      await container
          .read(appPreferencesProvider.notifier)
          .selectServer(server.id);
      expect((await store.load()).lastServerId, server.id);
      expect(prefs.getString(ServerStore.key), serverJson);
      expect((await threads.read(thread.id))!.toJson(), thread.toJson());
    },
  );

  test('stale preference fields do not discard usable selections', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      AppPreferencesStore.key,
      jsonEncode({
        'lastServerId': 'deleted-server',
        'lastHarnessIds': {
          'server-a': 'deleted-harness',
          'server-b': 42,
          'server-c': '',
          '': 'missing-server-id',
        },
        'feedFilter': 'obsolete-filter',
      }),
    );
    final restored = await AppPreferencesStore(SharedPreferences.getInstance)
        .load();
    // Resource availability is resolved by navigation, not the preference store.
    expect(restored.lastServerId, 'deleted-server');
    expect(restored.lastHarnessIds, {'server-a': 'deleted-harness'});
    expect(restored.feedFilter, 'all');
  });

  test('preference snapshots cannot be mutated through their harness map', () {
    final harnesses = {'server-a': 'harness-a'};
    final preferences = AppPreferences(lastHarnessIds: harnesses);
    harnesses['server-a'] = 'external-change';
    expect(preferences.lastHarnessIds, {'server-a': 'harness-a'});
    expect(
      () => preferences.lastHarnessIds['server-b'] = 'harness-b',
      throwsUnsupportedError,
    );
  });
}
