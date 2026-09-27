import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uhp_android/main.dart';
import 'package:uhp_android/message_content.dart';

const _server = ServerConfig(
  id: 'server',
  name: 'Server',
  baseUrl: 'https://example.test',
  apiKey: 'test-key',
);
ConversationThread _thread() => ConversationThread(
  id: 'local',
  title: '**Plain title**',
  server: _server,
  harnessId: 'h',
  harnessName: 'Research',
  serverSessionId: 'remote',
  serverSessionStatus: 'completed',
  serverLastResponseId: 'response',
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
  messages: [
    ThreadMessage(
      role: 'assistant',
      text: '**Stored answer**',
      createdAt: DateTime.utc(2026),
    ),
  ],
);

// Storage durability is covered by store tests; this seam keeps widget actions
// independent of native filesystem futures and Flutter's fake clock.
class _MemoryStore extends ThreadStore {
  _MemoryStore(ConversationThread thread)
    : super(() async => Directory.systemTemp) {
    threads[thread.id] = thread;
  }
  final threads = <String, ConversationThread>{};
  @override
  Future<ConversationThread?> read(String id) async => threads[id];
  @override
  Future<List<ThreadSummary>> loadIndex() async =>
      threads.values.map((t) => t.summary).toList();
  @override
  Future<List<ConversationThread>> continuingThreads() async => [];
  @override
  Future<void> save(ConversationThread thread) async {
    threads[thread.id] = thread;
  }

  @override
  Future<void> delete(String id) async {
    threads.remove(id);
  }

  @override
  Future<ConversationThread?> rename(String id, String title) async =>
      _update(id, {'title': title, 'localTitleOverride': title});
  @override
  Future<ConversationThread?> setArchived(String id, bool archived) async =>
      _update(id, {'archived': archived});
  ConversationThread? _update(String id, Map<String, Object> change) {
    final thread = threads[id];
    if (thread == null) return null;
    return threads[id] = ConversationThread.fromJson({
      ...thread.toJson(),
      ...change,
    });
  }
}

void main() {
  Future<
    ({
      ProviderContainer container,
      _MemoryStore store,
      List<http.Request> requests,
    })
  >
  mount(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      ServerStore.key: jsonEncode([_server.toJson()]),
      AppPreferencesStore.key: jsonEncode(
        AppPreferences(feedFilter: 'on-device').toJson(),
      ),
    });
    final thread = _thread();
    final store = _MemoryStore(thread);
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      if (request.method != 'GET' || !request.url.path.endsWith('/harnesses')) {
        throw StateError(
          'Unexpected network operation: ${request.method} ${request.url}',
        );
      }
      return http.Response('{"data":[{"id":"h","name":"Research"}]}', 200);
    });
    final container = ProviderContainer(
      overrides: [
        threadStoreProvider.overrideWithValue(store),
        httpClientProvider.overrideWithValue(client),
      ],
    );
    container.read(threadProvider.notifier).state = thread;
    addTearDown(() {
      container.dispose();
      client.close();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const UhpApp()),
    );
    await tester.pumpAndSettle();
    requests.clear();
    return (container: container, store: store, requests: requests);
  }

  Future<void> actions(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('thread-actions-local')));
    await tester.pumpAndSettle();
  }

  testWidgets('rename updates plain feed row and open chat header', (
    tester,
  ) async {
    await mount(tester);
    expect(find.text('**Plain title**'), findsOneWidget);
    expect(find.byType(MessageContent), findsNothing);
    await actions(tester);
    await tester.tap(find.widgetWithText(ListTile, 'Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Title'),
      '**Renamed title**',
    );
    await tester.tap(find.widgetWithText(TextButton, 'Rename'));
    await tester.pumpAndSettle();
    expect(find.text('**Renamed title**'), findsOneWidget);
    expect(find.text('**Plain title**'), findsNothing);
    expect(find.byType(MessageContent), findsNothing);
    await tester.tap(find.byTooltip('Current chat'));
    await tester.pumpAndSettle();
    expect(find.text('**Renamed title** · Research'), findsOneWidget);
  });

  testWidgets('archive hides rows by default and can be shown and unarchived', (
    tester,
  ) async {
    await mount(tester);
    await actions(tester);
    await tester.tap(find.widgetWithText(ListTile, 'Archive'));
    await tester.pumpAndSettle();
    expect(find.text('**Plain title**'), findsNothing);
    await tester.tap(find.widgetWithText(SwitchListTile, 'Show archived'));
    await tester.pumpAndSettle();
    expect(find.text('**Plain title**'), findsOneWidget);
    expect(find.textContaining('Archived · Research'), findsOneWidget);
    final muted = find
        .ancestor(
          of: find.byKey(const ValueKey('thread-local')),
          matching: find.byType(Opacity),
        )
        .first;
    expect(tester.widget<Opacity>(muted).opacity, lessThan(1));
    await actions(tester);
    await tester.tap(find.widgetWithText(ListTile, 'Unarchive'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SwitchListTile, 'Show archived'));
    await tester.pumpAndSettle();
    expect(find.text('**Plain title**'), findsOneWidget);
    expect(find.textContaining('Archived · Research'), findsNothing);
  });

  testWidgets(
    'deleting linked current chat is local only and clears the chat',
    (tester) async {
      final fixture = await mount(tester);
      await actions(tester);
      await tester.tap(find.widgetWithText(ListTile, 'Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(find.text('**Plain title**'), findsNothing);
      expect(find.byTooltip('Current chat'), findsNothing);
      expect(
        fixture.container.read(appDestinationProvider),
        AppDestination.feed,
      );
      expect(await fixture.store.read('local'), isNull);
      expect(await fixture.store.loadIndex(), isEmpty);
      expect(fixture.requests, isEmpty);
    },
  );

  for (final unsaved in [false, true]) {
    testWidgets(
      '${unsaved ? 'unsaved' : 'busy'} guard disables local management with a reason',
      (tester) async {
        final fixture = await mount(tester);
        await actions(tester);
        if (unsaved) {
          fixture.container.read(unsavedThreadProvider.notifier).state =
              _thread();
        } else {
          fixture.container.read(taskBusyProvider.notifier).state = true;
        }
        await tester.pumpAndSettle();
        expect(
          find.text(
            unsaved
                ? 'Save the completed turn before managing conversations.'
                : 'Finish the current turn before managing conversations.',
          ),
          findsOneWidget,
        );
        for (final label in ['Rename', 'Archive', 'Delete']) {
          final tile = tester.widget<ListTile>(
            find.widgetWithText(ListTile, label),
          );
          expect(tile.enabled, isFalse);
          expect(tile.onTap, isNull);
        }
        expect(fixture.requests, isEmpty);
      },
    );
  }

  testWidgets(
    'delete confirmation rechecks a turn started while dialog is open',
    (tester) async {
      final fixture = await mount(tester);
      await actions(tester);
      await tester.tap(find.widgetWithText(ListTile, 'Delete'));
      await tester.pumpAndSettle();
      fixture.container.read(taskBusyProvider.notifier).state = true;
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Delete'))
            .onPressed,
        isNull,
      );
      expect(await fixture.store.read('local'), isNotNull);
      expect(fixture.requests, isEmpty);
    },
  );
}
