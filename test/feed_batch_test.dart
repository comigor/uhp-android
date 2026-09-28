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
);

ConversationThread _thread(
  String id, {
  bool archived = false,
  String? status,
}) => ConversationThread(
  id: id,
  title: id,
  archived: archived,
  server: _server,
  harnessId: 'h',
  harnessName: 'Harness',
  serverSessionStatus: status,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
  messages: [
    ThreadMessage(
      role: 'assistant',
      text: 'Retained answer',
      createdAt: DateTime.utc(2026),
    ),
  ],
);

FeedTarget _remote(String id, {String status = ''}) => FeedTarget.remote(
  _server,
  ServerSession(id: id, title: 'Remote $id', status: status),
);

class _Fixture {
  _Fixture(this.container, this.store, this.ref, this.requests);
  final ProviderContainer container;
  final ThreadStore store;
  final WidgetRef ref;
  final List<http.Request> requests;
}

Future<_Fixture> _mount(
  WidgetTester tester,
  List<ConversationThread> threads, {
  AppPreferencesStore? preferences,
}) async {
  late Directory directory;
  await tester.runAsync(() async {
    directory = await Directory.systemTemp.createTemp('feed-batch-');
  });
  addTearDown(() => directory.delete(recursive: true));
  final store = ThreadStore(() async => directory);
  await tester.runAsync(() async {
    for (final thread in threads) {
      await store.save(thread);
    }
  });
  final requests = <http.Request>[];
  final client = MockClient((request) async {
    requests.add(request);
    throw StateError('Feed management must not access the network');
  });
  final container = ProviderContainer(
    overrides: [
      threadStoreProvider.overrideWithValue(store),
      httpClientProvider.overrideWithValue(client),
      if (preferences != null)
        appPreferencesStoreProvider.overrideWithValue(preferences),
    ],
  );
  addTearDown(() {
    container.dispose();
    client.close();
  });
  await tester.runAsync(() => container.read(appPreferencesProvider.future));
  late WidgetRef captured;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        scaffoldMessengerKey: container.read(appScaffoldMessengerKeyProvider),
        home: Consumer(
          builder: (context, ref, _) {
            captured = ref;
            return Scaffold(
              body: FeedSelectionBar(
                onSelectAll: () {
                  ref
                      .read(feedSelectionProvider.notifier)
                      .selectAll(
                        threads.map((t) => FeedTarget.local(t.summary)),
                      );
                },
              ),
            );
          },
        ),
      ),
    ),
  );
  return _Fixture(container, store, captured, requests);
}

Future<void> _act(
  WidgetTester tester,
  _Fixture fixture,
  FeedBatchAction action,
  List<FeedTarget> targets,
) async {
  await tester.runAsync(() => manageFeedBatch(fixture.ref, action, targets));
  await tester.pumpAndSettle();
}

Future<void> _undo(WidgetTester tester) async {
  await tester.runAsync(() async {
    await tester.tap(find.text('Undo'));
  });
  await tester.pumpAndSettle();
}

class _FailingPreferences extends AppPreferencesStore {
  _FailingPreferences() : super(SharedPreferences.getInstance);
  bool fail = false;
  @override
  Future<void> save(AppPreferences value) async {
    if (fail) throw const AppError('Preferences are read-only');
    await super.save(value);
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'selection combines types, deduplicates and excludes locked entries',
    () {
      final selection = FeedSelectionController();
      addTearDown(selection.dispose);
      final local = FeedTarget.local(_thread('same').summary);
      final remote = _remote('same');
      selection.toggle(local);
      selection.selectAll([
        local,
        remote,
        _remote('locked', status: 'running'),
      ]);
      expect(selection.state.keys.toSet(), {local.key, remote.key});
      selection.toggle(remote);
      expect(selection.state.values.single.isLocal, isTrue);
      selection.clear();
      expect(selection.state, isEmpty);
    },
  );

  testWidgets('mixed selection has type-aware counts and busy controls', (
    tester,
  ) async {
    final local = _thread('local');
    final fixture = await _mount(tester, [local]);
    fixture.container.read(feedSelectionProvider.notifier).selectAll([
      FeedTarget.local(local.summary),
      _remote('remote'),
    ]);
    await tester.pump();
    expect(find.text('Archive (1)'), findsOneWidget);
    expect(find.text('Hide (1)'), findsOneWidget);
    expect(find.text('Delete (1)'), findsOneWidget);
    fixture.container
        .read(feedSelectionProvider.notifier)
        .toggle(_remote('remote'));
    await tester.pump();
    expect(find.textContaining('Hide ('), findsNothing);
    fixture.container
        .read(feedSelectionProvider.notifier)
        .toggle(_remote('remote'));
    fixture.container
        .read(feedSelectionProvider.notifier)
        .toggle(FeedTarget.local(local.summary));
    await tester.pump();
    expect(find.textContaining('Archive ('), findsNothing);
    expect(find.textContaining('Delete ('), findsNothing);
    fixture.container
        .read(feedSelectionProvider.notifier)
        .toggle(FeedTarget.local(local.summary));
    fixture.container.read(taskBusyProvider.notifier).state = true;
    await tester.pump();
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Archive (1)'))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextButton>(
            find.widgetWithText(TextButton, 'Select all filtered'),
          )
          .onPressed,
      isNull,
    );
    await _act(tester, fixture, FeedBatchAction.hide, [_remote('remote')]);
    expect(
      fixture.container
          .read(appPreferencesProvider)
          .requireValue
          .hiddenSessions,
      isEmpty,
    );
    fixture.container.read(taskBusyProvider.notifier).state = false;
    fixture.container.read(unsavedThreadProvider.notifier).state = local;
    await _act(tester, fixture, FeedBatchAction.archive, [
      FeedTarget.local(local.summary),
    ]);
    await tester.runAsync(() async {
      expect((await fixture.store.read(local.id))!.archived, isFalse);
    });
  });

  testWidgets(
    'archive undo restores prior flags and keeps newer title and open messages',
    (tester) async {
      final first = _thread('first');
      final second = _thread('second', archived: true);
      final fixture = await _mount(tester, [first, second]);
      fixture.container.read(threadProvider.notifier).state = first;
      final targets = [
        FeedTarget.local(first.summary),
        FeedTarget.local(second.summary),
        _remote('remote'),
      ];
      fixture.container.read(feedSelectionProvider.notifier).selectAll(targets);
      await _act(tester, fixture, FeedBatchAction.archive, targets);
      expect(fixture.container.read(feedSelectionProvider), isEmpty);
      expect(fixture.container.read(sessionFeedRevisionProvider), 1);
      expect(
        fixture.container.read(threadProvider)!.messages.single.text,
        'Retained answer',
      );
      expect(fixture.container.read(threadProvider)!.archived, isTrue);
      await tester.runAsync(() async {
        final reopened = ThreadStore(fixture.store.documentsDirectory);
        expect((await reopened.read('first'))!.archived, isTrue);
        expect((await reopened.read('second'))!.archived, isTrue);
        await fixture.store.rename('first', 'Newer title');
      });
      await _undo(tester);
      await tester.runAsync(() async {
        // Waiting for the store queue also waits for the Undo write.
        final restored = await fixture.store.read('first');
        expect(restored!.archived, isFalse);
        expect(restored.title, 'Newer title');
        expect((await fixture.store.read('second'))!.archived, isTrue);
      });
      expect(fixture.requests, isEmpty);
    },
  );

  testWidgets(
    'hide undo restores old titles without reverting unrelated preferences',
    (tester) async {
      final fixture = await _mount(tester, []);
      final preferences = fixture.container.read(
        appPreferencesProvider.notifier,
      );
      await tester.runAsync(() async {
        await preferences.hideSession('server', 'old', 'Original title');
      });
      await _act(tester, fixture, FeedBatchAction.hide, [
        _remote('old'),
        _remote('new'),
      ]);
      await tester.runAsync(() async {
        await preferences.selectHarness('server', 'new-harness');
        await preferences.hideSession('server', 'unrelated', 'Keep this');
        await preferences.hideSession('other-server', 'elsewhere', 'Also keep');
      });
      await _undo(tester);
      await tester.runAsync(() async {
        // A following queued mutation is a barrier for the batch Undo.
        await preferences.setFeedFilter('on-device');
        final saved = await AppPreferencesStore(SharedPreferences.getInstance)
            .load();
        expect(saved.hiddenSessions, {
          'server': {'old': 'Original title', 'unrelated': 'Keep this'},
          'other-server': {'elsewhere': 'Also keep'},
        });
        expect(saved.lastHarnessIds['server'], 'new-harness');
      });
      expect(fixture.requests, isEmpty);
    },
  );

  testWidgets(
    'delete confirms, respects late busy state, and clears only deleted open thread',
    (tester) async {
      final local = _thread('local');
      final fixture = await _mount(tester, [local]);
      fixture.container.read(threadProvider.notifier).state = local;
      final targets = [FeedTarget.local(local.summary), _remote('remote')];
      late Future<void> pending;
      await tester.runAsync(() async {
        pending = manageFeedBatch(fixture.ref, FeedBatchAction.delete, targets);
      });
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      fixture.container.read(taskBusyProvider.notifier).state = true;
      await tester.pump();
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Delete'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.runAsync(() => pending);
      await tester.runAsync(() async {
        expect(
          (await fixture.store.read('local'))!.messages.single.text,
          'Retained answer',
        );
      });
      fixture.container.read(taskBusyProvider.notifier).state = false;
      late Future<void> confirmed;
      await tester.runAsync(() async {
        confirmed = manageFeedBatch(
          fixture.ref,
          FeedBatchAction.delete,
          targets,
        );
      });
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();
      await tester.runAsync(() => confirmed);
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        expect(
          await ThreadStore(fixture.store.documentsDirectory).read('local'),
          isNull,
        );
        expect(await fixture.store.loadIndex(), isEmpty);
      });
      expect(fixture.container.read(threadProvider), isNull);
      expect(find.text('Undo'), findsNothing);
      expect(fixture.requests, isEmpty);
    },
  );

  testWidgets(
    'legacy summary recheck skips running disk state and reports stale partial failure with Undo',
    (tester) async {
      final safe = _thread('safe');
      final locked = _thread('locked', status: 'in_progress');
      final fixture = await _mount(tester, [safe, locked]);
      final staleSummary = ThreadSummary.fromJson(
        {...locked.summary.toJson()}..remove('managementLocked'),
      );
      await _act(tester, fixture, FeedBatchAction.archive, [
        FeedTarget.local(safe.summary),
        FeedTarget.local(staleSummary),
        FeedTarget.local(_thread('missing').summary),
      ]);
      expect(find.textContaining('Archived 1.'), findsOneWidget);
      expect(find.textContaining('Skipped 1'), findsOneWidget);
      expect(find.textContaining('missing:'), findsOneWidget);
      await tester.runAsync(() async {
        expect((await fixture.store.read('safe'))!.archived, isTrue);
        expect((await fixture.store.read('locked'))!.archived, isFalse);
        expect(
          (await fixture.store.loadIndex())
              .firstWhere((t) => t.id == 'locked')
              .managementLocked,
          isTrue,
        );
      });
      await _undo(tester);
      await tester.runAsync(() async {
        expect((await fixture.store.read('safe'))!.archived, isFalse);
      });
    },
  );

  testWidgets(
    'failed preferences save preserves selection and reports error without Undo',
    (tester) async {
      final preferences = _FailingPreferences();
      final fixture = await _mount(tester, [], preferences: preferences);
      final target = _remote('remote');
      fixture.container.read(feedSelectionProvider.notifier).toggle(target);
      preferences.fail = true;
      await _act(tester, fixture, FeedBatchAction.hide, [target]);
      expect(find.textContaining('Preferences are read-only'), findsOneWidget);
      expect(find.text('Undo'), findsNothing);
      expect(fixture.container.read(feedSelectionProvider).keys, [target.key]);
      expect(
        fixture.container
            .read(appPreferencesProvider)
            .requireValue
            .hiddenSessions,
        isEmpty,
      );
      expect(fixture.container.read(feedMutationBusyProvider), isFalse);
    },
  );

  testWidgets('Undo rechecks unsaved guard and can be retried after saving', (
    tester,
  ) async {
    final local = _thread('local');
    final fixture = await _mount(tester, [local]);
    await _act(tester, fixture, FeedBatchAction.archive, [
      FeedTarget.local(local.summary),
    ]);
    fixture.container.read(unsavedThreadProvider.notifier).state = local;
    await _undo(tester);
    await tester.runAsync(() async {
      expect((await fixture.store.read('local'))!.archived, isTrue);
    });
    fixture.container.read(unsavedThreadProvider.notifier).state = null;
    await _undo(tester);
    await tester.runAsync(() async {
      expect((await fixture.store.read('local'))!.archived, isFalse);
    });
  });
}
