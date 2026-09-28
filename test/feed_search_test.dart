import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uhp_android/main.dart';

const _server = ServerConfig(
  id: 'search',
  name: 'Search server',
  baseUrl: 'https://example.test',
  apiKey: 'fixture',
);
ConversationThread _thread(
  String id,
  String title,
  String text, {
  bool archived = false,
}) => ConversationThread(
  id: id,
  title: title,
  archived: archived,
  server: _server,
  harnessId: 'research',
  harnessName: 'Research',
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
  messages: [
    ThreadMessage(role: 'user', text: text, createdAt: DateTime.utc(2026)),
  ],
);

class _Threads extends ThreadStore {
  _Threads() : super(() async => Directory.systemTemp);
  final rows = [
    _thread('local-one', 'Local alpha', 'A different prompt'),
    _thread(
      'local-two',
      'Local beta',
      'Find the Needle here\nsecond-line-only',
    ),
    _thread('archived', 'Archived needle', 'Needle', archived: true),
  ];
  @override
  Future<List<ThreadSummary>> loadIndex() async =>
      rows.map((t) => t.summary).toList();
  @override
  Future<List<ConversationThread>> continuingThreads() async => [];
  @override
  Future<ConversationThread?> read(String id) async =>
      rows.where((t) => t.id == id).firstOrNull;
}

Future<({ProviderContainer container, List<http.Request> requests})> _mount(
  WidgetTester tester,
) async {
  SharedPreferences.setMockInitialValues({
    ServerStore.key: jsonEncode([_server.toJson()]),
  });
  final requests = <http.Request>[];
  final client = MockClient((request) async {
    requests.add(request);
    if (request.method != 'GET') {
      throw StateError('Search cannot mutate the server');
    }
    if (request.url.path.endsWith('/harnesses')) {
      return http.Response(
        '{"data":[{"id":"research","name":"Research"},{"id":"writing","name":"Writing"}]}',
        200,
      );
    }
    if (!request.url.path.endsWith('/sessions')) {
      throw StateError('Search cannot fetch transcripts');
    }
    final harness = request.url.queryParameters['harness'];
    return http.Response(
      jsonEncode({
        'sessions': [
          if (harness == null || harness == 'research') ...[
            {
              'id': 'one',
              'title': 'Alpha project',
              'user_prompt': 'Ordinary prompt',
              'harnessId': 'research',
            },
            {
              'id': 'two',
              'title': 'Beta project',
              'user_prompt': 'Find the Needle here\nsecond-line-only',
              'harnessId': 'research',
            },
          ],
          if (harness == null || harness == 'writing')
            {
              'id': 'three',
              'title': 'Gamma project',
              'user_prompt': 'Another needle',
              'harnessId': 'writing',
            },
        ],
        'next_cursor': 'unloaded-page',
      }),
      200,
    );
  });
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
  return (container: container, requests: requests);
}

Finder get _input => find.byKey(const ValueKey('feed-search-input'));
Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Search sessions'));
  await tester.pumpAndSettle();
}

Future<void> _query(WidgetTester tester, String text) async {
  await tester.enterText(_input, text);
  await tester.pump(const Duration(milliseconds: 250));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'feed search debounces title fragments and clears without network reads',
    (tester) async {
      final fixture = await _mount(tester);
      await _open(tester);
      final before = fixture.requests.length;
      await tester.enterText(_input, 'aLPHa');
      await tester.pump(const Duration(milliseconds: 249));
      expect(find.text('Beta project'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.text('Alpha project'), findsOneWidget);
      expect(find.text('Beta project'), findsNothing);
      await _query(tester, '');
      expect(find.text('Alpha project'), findsOneWidget);
      expect(find.text('Beta project'), findsOneWidget);
      expect(find.text('Gamma project'), findsOneWidget);
      expect(fixture.requests.length, before);
    },
  );

  testWidgets(
    'first-line text search combines with harness and On-device filters',
    (tester) async {
      final fixture = await _mount(tester);
      await _open(tester);
      await _query(tester, 'NEEDLE');
      expect(find.text('Alpha project'), findsNothing);
      expect(find.text('Beta project'), findsOneWidget);
      expect(find.text('Gamma project'), findsOneWidget);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Research'));
      await tester.pumpAndSettle();
      expect(find.text('Beta project'), findsOneWidget);
      expect(find.text('Gamma project'), findsNothing);
      expect(fixture.requests.last.url.queryParameters['harness'], 'research');
      await tester.tap(find.widgetWithText(ChoiceChip, 'On-device'));
      await tester.pumpAndSettle();
      expect(find.text('Local beta'), findsOneWidget);
      expect(find.text('Local alpha'), findsNothing);
      expect(find.text('Archived needle'), findsNothing);
      await _query(tester, 'second-line-only');
      expect(find.text('Local beta'), findsNothing);
      await _query(tester, 'alpha');
      expect(find.text('Local alpha'), findsOneWidget);
      await tester.tap(find.byTooltip('Close feed search'));
      await tester.pumpAndSettle();
      expect(find.text('Local alpha'), findsOneWidget);
      expect(find.text('Local beta'), findsOneWidget);
      expect(fixture.container.read(feedSearchQueryProvider), isEmpty);
    },
  );

  testWidgets(
    'search select-all applies only to matching loaded rows without fetching another page',
    (tester) async {
      final fixture = await _mount(tester);
      await _open(tester);
      await _query(tester, 'beta');
      final before = fixture.requests.length;
      await tester.longPress(find.text('Beta project'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Select all filtered'));
      await tester.pumpAndSettle();
      expect(
        fixture.container
            .read(feedSelectionProvider)
            .values
            .map((target) => target.title),
        ['Beta project'],
      );
      expect(fixture.requests.length, before);
      expect(find.text('1 selected'), findsOneWidget);
    },
  );

  testWidgets(
    'retyping cancels stale debounce and Escape closes and clears search',
    (tester) async {
      final fixture = await _mount(tester);
      await _open(tester);
      await tester.enterText(_input, 'alpha');
      await tester.pump(const Duration(milliseconds: 200));
      await tester.enterText(_input, 'beta');
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('Gamma project'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Beta project'), findsOneWidget);
      expect(find.text('Alpha project'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(_input, findsNothing);
      expect(find.text('Alpha project'), findsOneWidget);
      expect(fixture.container.read(feedSearchQueryProvider), isEmpty);
    },
  );

  testWidgets('unmount cancels pending debounce without changing the query', (
    tester,
  ) async {
    final fixture = await _mount(tester);
    await _open(tester);
    await tester.enterText(_input, 'never applied');
    await tester.pumpWidget(const SizedBox.shrink());
    expect(fixture.container.read(feedSearchQueryProvider), isEmpty);
    // The widget-test binding also rejects a pending Timer at teardown.
  });

  testWidgets('Android Back closes feed search without leaving the feed', (
    tester,
  ) async {
    final fixture = await _mount(tester);
    await _open(tester);
    await _query(tester, 'alpha');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(_input, findsNothing);
    expect(fixture.container.read(appDestinationProvider), AppDestination.feed);
    expect(find.text('Beta project'), findsOneWidget);
  });
}
