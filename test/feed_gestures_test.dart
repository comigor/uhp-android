import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uhp_android/main.dart';

const _server = ServerConfig(
  id: 'server',
  name: 'Server',
  baseUrl: 'https://example.test',
  apiKey: 'fixture',
);
ConversationThread _thread(
  String id, {
  bool archived = false,
  bool locked = false,
}) => ConversationThread(
  id: id,
  title: id,
  archived: archived,
  server: _server,
  harnessId: 'h',
  harnessName: 'Research',
  serverSessionStatus: locked ? 'running' : null,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
  messages: const [],
);

// Gesture timing is isolated from native I/O; feed_batch_test covers durable writes.
class _Store extends ThreadStore {
  _Store() : super(() async => Directory.systemTemp);
  final threads = {
    for (final thread in [
      _thread('Local-one'),
      _thread('Local-two'),
      _thread('Archived', archived: true),
      _thread('Locked', locked: true),
    ])
      thread.id: thread,
  };
  @override
  Future<List<ThreadSummary>> loadIndex() async =>
      threads.values.map((t) => t.summary).toList();
  @override
  Future<List<ConversationThread>> continuingThreads() async => [];
  @override
  Future<ConversationThread?> read(String id) async => threads[id];
  @override
  Future<ConversationThread?> readForManagement(String id) => read(id);
  @override
  Future<ConversationThread?> mutateFeedThread(
    String id,
    FeedBatchAction action, {
    required void Function(ConversationThread) beforeWrite,
  }) async {
    final before = threads[id]!;
    beforeWrite(before);
    if (before.managementLocked) throw const AppError('Locked');
    if (action == FeedBatchAction.delete) {
      threads.remove(id);
      return null;
    }
    return threads[id] = ConversationThread.fromJson({
      ...before.toJson(),
      'archived': action == FeedBatchAction.archive,
    });
  }
}

Future<
  ({ProviderContainer container, _Store store, List<http.Request> requests})
>
_mount(WidgetTester tester, {bool local = false}) async {
  SharedPreferences.setMockInitialValues({
    ServerStore.key: jsonEncode([_server.toJson()]),
    AppPreferencesStore.key: jsonEncode(
      AppPreferences(feedFilter: local ? 'on-device' : 'all').toJson(),
    ),
  });
  final store = _Store();
  final requests = <http.Request>[];
  final client = MockClient((request) async {
    requests.add(request);
    if (request.method != 'GET') {
      throw StateError('Unexpected mutation: ${request.method}');
    }
    if (request.url.path.endsWith('/harnesses')) {
      return http.Response('{"data":[{"id":"h","name":"Research"}]}', 200);
    }
    if (!request.url.path.endsWith('/sessions')) {
      throw StateError('Unexpected request: ${request.url}');
    }
    final next = request.url.queryParameters['cursor'] != null;
    return http.Response(
      jsonEncode({
        'sessions': [
          {
            'id': next ? 'two' : 'one',
            'title': next ? 'Remote two' : 'Remote one',
            'harnessId': 'h',
            'status': 'completed',
          },
        ],
        if (!next) 'next_cursor': 'next-page',
      }),
      200,
    );
  });
  final container = ProviderContainer(
    overrides: [
      threadStoreProvider.overrideWithValue(store),
      httpClientProvider.overrideWithValue(client),
    ],
  );
  addTearDown(() {
    container.dispose();
    client.close();
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const UhpApp()),
  );
  await tester.pumpAndSettle();
  return (container: container, store: store, requests: requests);
}

Future<void> _swipe(
  WidgetTester tester,
  String key, {
  bool reverse = false,
}) async {
  await tester.drag(find.byKey(ValueKey(key)), Offset(reverse ? -600 : 600, 0));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('archive and unarchive gestures persist and Undo restores each', (
    tester,
  ) async {
    final fixture = await _mount(tester, local: true);
    await _swipe(tester, 'thread-Local-one');
    expect(fixture.store.threads['Local-one']!.archived, isTrue);
    expect(find.text('Local-one'), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(fixture.store.threads['Local-one']!.archived, isFalse);
    expect(find.text('Local-one'), findsOneWidget);
    await tester.tap(find.widgetWithText(SwitchListTile, 'Show archived'));
    await tester.pumpAndSettle();
    await _swipe(tester, 'thread-Archived', reverse: true);
    expect(fixture.store.threads['Archived']!.archived, isFalse);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(fixture.store.threads['Archived']!.archived, isTrue);
  });

  testWidgets('server hide gesture and Undo only update local preferences', (
    tester,
  ) async {
    final fixture = await _mount(tester);
    await _swipe(tester, 'session-one');
    expect(find.text('Remote one'), findsNothing);
    expect(
      (await AppPreferencesStore(
        SharedPreferences.getInstance,
      ).load()).hiddenSessions['server'],
      {'one': 'Remote one'},
    );
    expect(find.byType(AlertDialog), findsNothing);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(find.text('Remote one'), findsOneWidget);
    expect(
      (await AppPreferencesStore(
        SharedPreferences.getInstance,
      ).load()).hiddenSessions,
      isEmpty,
    );
    expect(
      fixture.requests.every((request) => request.method == 'GET'),
      isTrue,
    );
  });

  testWidgets(
    'selection crosses filters; select all fetches remaining pages; batch hide undoes all',
    (tester) async {
      final fixture = await _mount(tester, local: true);
      await tester.longPress(find.text('Local-one'));
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);
      expect(find.text('Hide (0)'), findsNothing);
      await tester.tap(find.text('Select all filtered'));
      await tester.pumpAndSettle();
      expect(find.text('2 selected'), findsOneWidget);
      expect(
        fixture.container
            .read(feedSelectionProvider)
            .values
            .map((t) => t.title),
        unorderedEquals(['Local-one', 'Local-two']),
      );
      await tester.tap(find.widgetWithText(ChoiceChip, 'Research'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Select all filtered'));
      await tester.pumpAndSettle();
      expect(find.text('4 selected'), findsOneWidget);
      expect(find.text('Archive (2)'), findsOneWidget);
      expect(find.text('Hide (2)'), findsOneWidget);
      expect(find.text('Delete (2)'), findsOneWidget);
      expect(
        fixture.requests.last.url.queryParameters,
        containsPair('harness', 'h'),
      );
      expect(
        fixture.requests.last.url.queryParameters,
        containsPair('cursor', 'next-page'),
      );
      await tester.tap(find.text('Hide (2)'));
      await tester.pumpAndSettle();
      expect(find.text('Sessions'), findsOneWidget);
      expect(find.text('Remote one'), findsNothing);
      expect(fixture.store.threads['Local-one']!.archived, isFalse);
      expect(fixture.store.threads['Local-two']!.archived, isFalse);
      expect(
        (await AppPreferencesStore(
          SharedPreferences.getInstance,
        ).load()).hiddenSessions['server']!.keys,
        unorderedEquals(['one', 'two']),
      );
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(
        (await AppPreferencesStore(
          SharedPreferences.getInstance,
        ).load()).hiddenSessions,
        isEmpty,
      );
    },
  );

  testWidgets(
    'selection disables swipes and both X and Android back leave feed open',
    (tester) async {
      final fixture = await _mount(tester, local: true);
      await tester.longPress(find.text('Local-one'));
      await tester.pumpAndSettle();
      await _swipe(tester, 'thread-Local-two');
      expect(fixture.store.threads['Local-two']!.archived, isFalse);
      expect(find.text('1 selected'), findsOneWidget);
      await tester.tap(find.byTooltip('Cancel selection'));
      await tester.pumpAndSettle();
      expect(fixture.container.read(feedSelectionProvider), isEmpty);
      await tester.longPress(find.text('Local-one'));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Sessions'), findsOneWidget);
      expect(fixture.container.read(feedSelectionProvider), isEmpty);
      expect(
        fixture.container.read(appDestinationProvider),
        AppDestination.feed,
      );
    },
  );

  for (final unsaved in [false, true]) {
    testWidgets(
      '${unsaved ? 'unsaved' : 'busy'} guards block selection and swipe on both row types',
      (tester) async {
        final fixture = await _mount(tester, local: true);
        if (unsaved) {
          fixture.container.read(unsavedThreadProvider.notifier).state =
              _thread('Draft');
        } else {
          fixture.container.read(taskBusyProvider.notifier).state = true;
        }
        await tester.pumpAndSettle();
        await tester.longPress(find.text('Local-one'));
        await _swipe(tester, 'thread-Local-one');
        expect(fixture.container.read(feedSelectionProvider), isEmpty);
        expect(fixture.store.threads['Local-one']!.archived, isFalse);
        await fixture.container
            .read(appPreferencesProvider.notifier)
            .setFeedFilter('all');
        await tester.pumpAndSettle();
        await tester.longPress(find.text('Remote one'));
        await _swipe(tester, 'session-one');
        expect(fixture.container.read(feedSelectionProvider), isEmpty);
        expect(
          fixture.container
              .read(appPreferencesProvider)
              .requireValue
              .hiddenSessions,
          isEmpty,
        );
      },
    );
  }

  testWidgets('running local rows cannot be selected or swiped', (
    tester,
  ) async {
    final fixture = await _mount(tester, local: true);
    await tester.longPress(find.text('Locked'));
    await _swipe(tester, 'thread-Locked');
    expect(fixture.container.read(feedSelectionProvider), isEmpty);
    expect(fixture.store.threads['Locked']!.archived, isFalse);
  });

  testWidgets(
    'vertical pull refresh still fetches sessions without hiding them',
    (tester) async {
      final fixture = await _mount(tester);
      final before = fixture.requests.length;
      await tester.drag(
        find.byKey(const ValueKey('session-one')),
        const Offset(0, 360),
      );
      await tester.pumpAndSettle();
      expect(fixture.requests.length, greaterThan(before));
      expect(find.text('Remote one'), findsOneWidget);
      expect(
        fixture.container
            .read(appPreferencesProvider)
            .requireValue
            .hiddenSessions,
        isEmpty,
      );
    },
  );
}
