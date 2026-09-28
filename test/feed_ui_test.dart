import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uhp_android/main.dart';

const _first = ServerConfig(
  id: 'first',
  name: 'First server',
  baseUrl: 'https://first.test',
  apiKey: 'first-key',
);
const _second = ServerConfig(
  id: 'second',
  name: 'Second server',
  baseUrl: 'https://second.test',
  apiKey: 'second-key',
);
const _harnesses = [
  {'id': 'h1', 'name': 'Research', 'defaultModel': 'model-a'},
  {'id': 'h2', 'name': 'Writing', 'defaultModel': 'model-b'},
];

// Widget tests exercise navigation, not filesystem scheduling. The unchanged
// persistence suites cover ThreadStore's disk serialization and restart behavior.
class _Threads extends ThreadStore {
  _Threads() : super(() async => Directory.systemTemp);
  final _threads = <String, ConversationThread>{};
  @override
  Future<void> save(ConversationThread thread) async {
    _threads[thread.id] = thread;
  }

  @override
  Future<ConversationThread?> read(String id) async => _threads[id];
  @override
  Future<List<ThreadSummary>> loadIndex() async =>
      _threads.values.map((t) => t.summary).toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  @override
  Future<List<ConversationThread>> continuingThreads() async => [];
}

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

Future<ProviderContainer> _mount(
  WidgetTester tester,
  Future<http.Response> Function(http.Request) handler, {
  AppPreferences? preferences,
}) async {
  SharedPreferences.setMockInitialValues({
    ServerStore.key: jsonEncode([_first.toJson(), _second.toJson()]),
    if (preferences != null)
      AppPreferencesStore.key: jsonEncode(preferences.toJson()),
  });
  final client = MockClient(handler);
  final container = ProviderContainer(
    overrides: [
      httpClientProvider.overrideWithValue(client),
      threadStoreProvider.overrideWithValue(_Threads()),
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
  return container;
}

void main() {
  for (final scenario in [
    (
      name: 'first profile without a preference',
      remembered: null,
      expected: _first,
    ),
    (
      name: 'last-used profile after restart',
      remembered: 'second',
      expected: _second,
    ),
    (
      name: 'first profile when remembered profile was deleted',
      remembered: 'deleted',
      expected: _first,
    ),
  ]) {
    testWidgets('launch selects ${scenario.name} without a connection test', (
      tester,
    ) async {
      final requests = <http.Request>[];
      await _mount(tester, (request) async {
        requests.add(request);
        return request.url.path.endsWith('/harnesses')
            ? _json({'data': _harnesses})
            : _json({'sessions': []});
      }, preferences: AppPreferences(lastServerId: scenario.remembered));
      expect(find.text('Sessions'), findsOneWidget);
      expect(find.text(scenario.expected.name), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      expect(requests.map((request) => request.url.path).toSet(), {
        '/api/harness/v1/harnesses',
        '/api/harness/v1/sessions',
      });
      expect(
        requests.every(
          (request) =>
              request.url.host == Uri.parse(scenario.expected.baseUrl).host,
        ),
        isTrue,
      );
      expect(
        requests.every(
          (request) =>
              request.headers['Authorization'] ==
              'Bearer ${scenario.expected.apiKey}',
        ),
        isTrue,
      );
      final persisted = await AppPreferencesStore(SharedPreferences.getInstance)
          .load();
      expect(persisted.lastServerId, scenario.expected.id);
    });
  }

  testWidgets(
    'All is unfiltered and newest-first; chips persist and show local history',
    (tester) async {
      final queries = <Map<String, String>>[];
      final container = await _mount(tester, (request) async {
        if (request.url.path.endsWith('/harnesses')) {
          return _json({'data': _harnesses});
        }
        queries.add(request.url.queryParameters);
        return _json({
          'sessions': [
            if (!request.url.queryParameters.containsKey('harness'))
              {
                'id': 'older',
                'title': 'Research session',
                'harnessId': 'h1',
                'updatedAt': '2026-01-01T00:00:00Z',
                'status': 'done',
              },
            {
              'id': 'newer',
              'title': 'Writing session',
              'harnessId': 'h2',
              'updatedAt': '2026-02-01T00:00:00Z',
              'status': 'running',
            },
          ],
        });
      });
      expect(queries.single.containsKey('harness'), isFalse);
      expect(find.text('Research session'), findsOneWidget);
      expect(find.text('Writing session'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Writing session')).dy,
        lessThan(tester.getTopLeft(find.text('Research session')).dy),
      );
      await tester.tap(find.widgetWithText(ChoiceChip, 'Writing'));
      await tester.pumpAndSettle();
      expect(queries.last['harness'], 'h2');
      expect(find.text('Research session'), findsNothing);
      expect(
        (await AppPreferencesStore(
          SharedPreferences.getInstance,
        ).load()).feedFilter,
        'harness:h2',
      );
      final now = DateTime.utc(2026);
      await container
          .read(threadStoreProvider)
          .save(
            ConversationThread(
              id: 'local-thread',
              title: 'Saved on this device',
              server: _first,
              harnessId: 'h1',
              harnessName: 'Research',
              createdAt: now,
              updatedAt: now,
              messages: const [],
            ),
          );
      await tester.tap(find.widgetWithText(ChoiceChip, 'On-device'));
      await tester.pumpAndSettle();
      expect(find.text('Saved on this device'), findsOneWidget);
      expect(find.text('Writing session'), findsNothing);
      expect(queries, hasLength(2));
      expect(
        (await AppPreferencesStore(
          SharedPreferences.getInstance,
        ).load()).feedFilter,
        'on-device',
      );
      await tester.tap(find.widgetWithText(ChoiceChip, 'All'));
      await tester.pumpAndSettle();
      expect(queries.last.containsKey('harness'), isFalse);
    },
  );

  testWidgets(
    'pagination retains all rows and passes the opaque cursor unchanged',
    (tester) async {
      final cursors = <String?>[];
      await _mount(tester, (request) async {
        if (request.url.path.endsWith('/harnesses')) {
          return _json({'data': _harnesses});
        }
        final cursor = request.url.queryParameters['cursor'];
        cursors.add(cursor);
        return _json({
          'sessions': [
            {
              'id': cursor == null ? 'one' : 'two',
              'title': cursor == null ? 'First page' : 'Second page',
              'harnessId': 'h1',
            },
          ],
          if (cursor == null) 'next_cursor': 'opaque+/=cursor',
        });
      });
      await tester.tap(find.text('Load more'));
      await tester.pumpAndSettle();
      expect(cursors, [null, 'opaque+/=cursor']);
      expect(find.text('First page'), findsOneWidget);
      expect(find.text('Second page'), findsOneWidget);
      expect(find.text('Load more'), findsNothing);
    },
  );

  for (final remembered in <String?>[null, 'h2', 'removed-harness']) {
    testWidgets(
      'New chat confirms remembered harness $remembered or the first default',
      (tester) async {
        final submitted = <Map<String, dynamic>>[];
        final container = await _mount(tester, (request) async {
          if (request.method == 'POST') {
            submitted.add(jsonDecode(request.body) as Map<String, dynamic>);
            return _json({
              'id': 'response-1',
              'output': [
                {
                  'role': 'assistant',
                  'content': [
                    {'text': 'Default model answer'},
                  ],
                },
              ],
            });
          }
          return request.url.path.endsWith('/harnesses')
              ? _json({'data': _harnesses})
              : _json({'sessions': []});
        }, preferences: AppPreferences(lastHarnessIds: {'first': ?remembered}));
        await tester.tap(find.text('New chat'));
        await tester.pumpAndSettle();
        expect(find.text('Choose a harness'), findsOneWidget);
        await tester.tap(find.text('Start chat'));
        await tester.pumpAndSettle();
        final expected = remembered == 'h2' ? 'h2' : 'h1';
        expect(find.text('Chat'), findsOneWidget);
        expect(find.text('Model: Harness default'), findsOneWidget);
        expect(
          (await AppPreferencesStore(
            SharedPreferences.getInstance,
          ).load()).lastHarnessIds['first'],
          expected,
        );
        await tester.enterText(
          find.widgetWithText(TextField, 'Prompt'),
          'A fresh prompt',
        );
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();
        // StreamSubscription.cancel may use Dart's root-zone cached future.
        await tester.runAsync(() async {});
        await tester.pumpAndSettle();
        expect((submitted.single['metadata'] as Map)['harness_id'], expected);
        expect(submitted.single.containsKey('model'), isFalse);
        expect(submitted.single.containsKey('previous_response_id'), isFalse);
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(ChoiceChip, 'On-device'));
        await tester.pumpAndSettle();
        container.read(threadProvider.notifier).state = null;
        await tester.tap(find.widgetWithText(ListTile, 'New chat'));
        await tester.pumpAndSettle();
        expect(
          find.text('Default model answer', findRichText: true),
          findsOneWidget,
        );
      },
    );
  }

  testWidgets(
    'failed feed keeps filters accessible; Retry reloads and Edit server opens Settings',
    (tester) async {
      var fail = true;
      var calls = 0;
      await _mount(tester, (request) async {
        if (request.url.path.endsWith('/harnesses')) {
          return _json({'data': _harnesses});
        }
        calls++;
        return fail
            ? _json({'error': 'Access denied'}, 401)
            : _json({
                'sessions': [
                  {'id': 'restored', 'title': 'Recovered session'},
                ],
              });
      });
      expect(find.textContaining('401'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'On-device'), findsOneWidget);
      await tester.tap(find.text('Edit server'));
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('Servers'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      final before = calls;
      fail = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(calls, before + 1);
      expect(find.text('Recovered session'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
    },
  );

  testWidgets('missing harnesses leave feed usable and offer Settings inline', (
    tester,
  ) async {
    await _mount(
      tester,
      (request) async => request.url.path.endsWith('/harnesses')
          ? _json({'data': []})
          : _json({'sessions': []}),
    );
    await tester.tap(find.text('New chat'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No harnesses available'), findsOneWidget);
    expect(find.text('Sessions'), findsOneWidget);
    await tester.tap(find.text('Open Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);
  });
}
