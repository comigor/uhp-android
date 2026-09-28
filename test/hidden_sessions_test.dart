import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uhp_android/main.dart';

const _server = ServerConfig(
  id: 'first',
  name: 'First server',
  baseUrl: 'https://first.test',
  apiKey: 'test-key',
);
const _otherServer = ServerConfig(
  id: 'second',
  name: 'Second server',
  baseUrl: 'https://second.test',
  apiKey: 'test-key',
);
const _title = '**Plain** [session](https://example.test)';
final _localThread = ConversationThread(
  id: 'local',
  title: 'Local copy',
  server: _server,
  serverSessionId: 'shared',
  harnessId: 'research',
  harnessName: 'Research',
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
  messages: const [],
);

Future<void> _surface(
  WidgetTester tester,
  ProviderContainer container,
  Widget child,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        scaffoldMessengerKey: container.read(appScaffoldMessengerKeyProvider),
        home: Scaffold(body: child),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<ProviderContainer> _mount(
  WidgetTester tester,
  List<http.Request> requests,
) async {
  SharedPreferences.setMockInitialValues({
    ServerStore.key: jsonEncode([_server.toJson(), _otherServer.toJson()]),
  });
  final client = MockClient((request) async {
    requests.add(request);
    final more = request.url.queryParameters.containsKey('cursor');
    return http.Response(
      jsonEncode(
        request.url.path.endsWith('/harnesses')
            ? {
                'data': [
                  {
                    'id': 'research',
                    'name': 'Research',
                    'defaultModel': 'model',
                  },
                ],
              }
            : {
                'sessions': [
                  {
                    'id': more ? 'next' : 'shared',
                    'title': more ? 'Next page' : _title,
                    'harnessId': 'research',
                  },
                ],
                if (!more) 'next_cursor': 'opaque+/=cursor',
              },
      ),
      200,
    );
  });
  final container = ProviderContainer(
    overrides: [
      httpClientProvider.overrideWithValue(client),
      historyProvider.overrideWith((ref) async => [_localThread.summary]),
    ],
  );
  addTearDown(container.dispose);
  addTearDown(client.close);
  await container.read(appPreferencesProvider.future);
  container.read(selectedServerProvider.notifier).state = _server;
  await _surface(tester, container, const SessionsFeed());
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'queued hiding and restoring persist and isolate equal session IDs',
    () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(appPreferencesProvider.notifier);
      await Future.wait([
        controller.hideSession('first', 'shared', _title),
        controller.selectHarness('first', 'research'),
        controller.hideSession('second', 'shared', 'Other title'),
        controller.hideSession('first', 'temporary', 'Temporary'),
        controller.setFeedFilter('harness:research'),
        controller.restoreSession('first', 'temporary'),
      ]);
      final reopened = ProviderContainer();
      addTearDown(reopened.dispose);
      final saved = await reopened.read(appPreferencesProvider.future);
      expect(saved.hiddenSessions, {
        'first': {'shared': _title},
        'second': {'shared': 'Other title'},
      });
      expect(saved.lastHarnessIds, {'first': 'research'});
      expect(saved.feedFilter, 'harness:research');
      await reopened
          .read(appPreferencesProvider.notifier)
          .restoreSession('first', 'shared');
      final restored = await AppPreferencesStore(SharedPreferences.getInstance)
          .load();
      expect(restored.hiddenSessions, {
        'second': {'shared': 'Other title'},
      });
    },
  );

  test(
    'hidden preferences recover usable entries and make deep snapshots',
    () async {
      SharedPreferences.setMockInitialValues({
        AppPreferencesStore.key: jsonEncode({
          'lastServerId': 'first',
          'hiddenSessions': {
            'first': {'shared': _title, 'invalid': 42, '': 'Missing ID'},
            'second': false,
            '': {'shared': 'Missing server'},
          },
        }),
      });
      final saved = await AppPreferencesStore(SharedPreferences.getInstance)
          .load();
      expect(saved.lastServerId, 'first');
      expect(saved.hiddenSessions, {
        'first': {'shared': _title},
      });
      final input = <String, Map<String, String>>{
        'first': {'shared': _title},
      };
      final snapshot = AppPreferences(hiddenSessions: input);
      input['first']!['shared'] = 'Changed outside';
      input.clear();
      expect(snapshot.hiddenSessions['first']!['shared'], _title);
      expect(() => snapshot.hiddenSessions.clear(), throwsUnsupportedError);
      expect(
        () => snapshot.hiddenSessions['first']!.clear(),
        throwsUnsupportedError,
      );
      expect(
        AppPreferences.fromJson({'hiddenSessions': []}).hiddenSessions,
        isEmpty,
      );
    },
  );

  testWidgets(
    'hide, paginate, isolate servers, retain local copy and restore in Settings',
    (tester) async {
      final requests = <http.Request>[];
      final container = await _mount(tester, requests);
      expect(find.text(_title), findsOneWidget);
      await tester.tap(find.byTooltip('Session options'));
      await tester.pumpAndSettle();
      expect(find.text('Rename'), findsNothing);
      expect(find.text('Delete'), findsNothing);
      final beforeHide = requests.length;
      await tester.tap(find.text('Hide from feed'));
      await tester.pumpAndSettle();
      expect(find.text(_title), findsNothing);
      expect(requests.length, beforeHide);
      container.invalidate(appPreferencesProvider);
      await tester.pumpAndSettle();
      expect(find.text(_title), findsNothing);

      await tester.tap(find.text('Load more'));
      await tester.pumpAndSettle();
      expect(requests.last.url.queryParameters['cursor'], 'opaque+/=cursor');
      expect(find.text('Next page'), findsOneWidget);
      expect(find.text(_title), findsNothing);
      expect(find.text('Load more'), findsNothing);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Research'));
      await tester.pumpAndSettle();
      expect(requests.last.url.queryParameters['harness'], 'research');
      expect(find.text(_title), findsNothing);
      expect(find.text('Load more'), findsOneWidget);

      await tester.tap(find.widgetWithText(ChoiceChip, 'On-device'));
      await tester.pumpAndSettle();
      expect(find.text('Local copy'), findsOneWidget);
      container.read(selectedServerProvider.notifier).state = _otherServer;
      await tester.tap(find.widgetWithText(ChoiceChip, 'All'));
      await tester.pumpAndSettle();
      expect(find.text(_title), findsOneWidget);
      container.read(selectedServerProvider.notifier).state = _server;
      await tester.pumpAndSettle();
      expect(find.text(_title), findsNothing);

      await _surface(tester, container, const SettingsScreen());
      await tester.tap(find.text('Hidden sessions').first);
      await tester.pumpAndSettle();
      expect(find.text(_title), findsOneWidget);
      final beforeRestore = requests.length;
      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();
      expect(find.text(_title), findsNothing);
      expect(requests.length, beforeRestore);
      await _surface(tester, container, const SessionsFeed());
      expect(find.text(_title), findsOneWidget);
      expect(requests.every((request) => request.method == 'GET'), isTrue);
    },
  );

  for (final unsaved in [false, true]) {
    testWidgets(
      '${unsaved ? 'unsaved turn' : 'busy task'} disables hide and restore, including stale actions',
      (tester) async {
        final requests = <http.Request>[];
        final container = await _mount(tester, requests);
        void block(bool value) {
          if (unsaved) {
            container.read(unsavedThreadProvider.notifier).state = value
                ? _localThread
                : null;
          } else {
            container.read(taskBusyProvider.notifier).state = value;
          }
        }

        await tester.tap(find.byTooltip('Session options').first);
        await tester.pumpAndSettle();
        block(true);
        await tester.pumpAndSettle();
        final disabledHide = tester.widget<ListTile>(
          find.widgetWithText(ListTile, 'Hide from feed'),
        );
        expect(disabledHide.onTap, isNull);
        expect(
          find.textContaining('before hiding or restoring sessions'),
          findsOneWidget,
        );
        block(false);
        await tester.pumpAndSettle();
        final hide = tester
            .widget<ListTile>(find.widgetWithText(ListTile, 'Hide from feed'))
            .onTap!;
        hide();
        block(true);
        await tester.pumpAndSettle();
        expect(
          container.read(appPreferencesProvider).requireValue.hiddenSessions,
          isEmpty,
        );
        expect(find.text(_title), findsOneWidget);

        block(false);
        await container
            .read(appPreferencesProvider.notifier)
            .hideSession('first', 'shared', _title);
        await _surface(tester, container, const SettingsScreen());
        await tester.tap(find.text('Hidden sessions').first);
        await tester.pumpAndSettle();
        final restore = tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Restore'))
            .onPressed!;
        block(true);
        restore();
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextButton>(find.widgetWithText(TextButton, 'Restore'))
              .onPressed,
          isNull,
        );
        expect(
          find.textContaining('before hiding or restoring sessions'),
          findsOneWidget,
        );
        expect(
          container
              .read(appPreferencesProvider)
              .requireValue
              .hiddenSessions['first'],
          {'shared': _title},
        );
        expect(requests.every((request) => request.method == 'GET'), isTrue);
      },
    );
  }
}
