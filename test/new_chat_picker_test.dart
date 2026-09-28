import 'dart:async';
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
  id: 'picker-server',
  name: 'Picker server',
  baseUrl: 'https://picker.test',
  apiKey: 'test-key',
);
const _otherServer = ServerConfig(
  id: 'other-server',
  name: 'Other server',
  baseUrl: 'https://other.test',
  apiKey: 'other-key',
);
const _catalog = [
  {
    'id': 'research',
    'name': 'Research',
    'base_label': 'Analyst',
    'default_model': 'model-research',
  },
  {
    'id': 'writing',
    'name': 'Writing',
    'base_label': 'Author',
    'default_model': 'model-writing',
  },
  {
    'id': 'coding',
    'name': 'Coding',
    'base_label': 'Developer',
    'default_model': 'model-coding',
  },
];

class _Threads extends ThreadStore {
  _Threads() : super(() async => Directory.systemTemp);
  final saved = <String, ConversationThread>{};

  @override
  Future<void> save(ConversationThread thread) async {
    saved[thread.id] = thread;
  }

  @override
  Future<ConversationThread?> read(String id) async => saved[id];

  @override
  Future<List<ThreadSummary>> loadIndex() async =>
      saved.values.map((thread) => thread.summary).toList();

  @override
  Future<List<ConversationThread>> continuingThreads() async => [];
}

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

Future<ProviderContainer> _mount(
  WidgetTester tester, {
  Future<http.Response> Function(http.Request)? harnessResponse,
  String? remembered,
}) async {
  SharedPreferences.setMockInitialValues({
    ServerStore.key: jsonEncode([_server.toJson(), _otherServer.toJson()]),
    AppPreferencesStore.key: jsonEncode(
      AppPreferences(
        lastServerId: _server.id,
        lastHarnessIds: {_server.id: ?remembered},
      ).toJson(),
    ),
  });
  final client = MockClient((request) async {
    if (request.url.path.endsWith('/harnesses')) {
      return harnessResponse == null
          ? _json({'data': _catalog})
          : await harnessResponse(request);
    }
    return _json({'sessions': []});
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
  return container;
}

Finder _inSheet(Finder matching) =>
    find.descendant(of: find.byType(BottomSheet), matching: matching);

Future<void> _openPicker(WidgetTester tester) async {
  await tester.tap(find.text('New chat'));
  await tester.pumpAndSettle();
  expect(find.text('Choose a harness'), findsOneWidget);
}

Future<void> _expectUnchanged(
  ProviderContainer container, {
  String? remembered,
}) async {
  expect(container.read(threadProvider), isNull);
  expect(await container.read(threadStoreProvider).loadIndex(), isEmpty);
  expect(container.read(appDestinationProvider), AppDestination.feed);
  final preferences = await AppPreferencesStore(SharedPreferences.getInstance)
      .load();
  expect(preferences.lastHarnessIds, {_server.id: ?remembered});
}

void main() {
  testWidgets('API harness rows show labels and models; tapped row is saved', (
    tester,
  ) async {
    final container = await _mount(tester);
    await _openPicker(tester);
    for (final harness in _catalog) {
      expect(_inSheet(find.text(harness['name']!)), findsOneWidget);
      expect(
        _inSheet(find.widgetWithText(Chip, harness['base_label']!)),
        findsOneWidget,
      );
      expect(
        _inSheet(find.text('Default model: ${harness['default_model']}')),
        findsOneWidget,
      );
    }
    await _expectUnchanged(container);
    await tester.tap(find.byKey(const ValueKey('new-chat-harness-writing')));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('Chat'), findsOneWidget);
    final thread = container.read(threadProvider)!;
    expect(thread.harnessId, 'writing');
    expect(thread.harnessName, 'Writing');
    expect(thread.server.id, _server.id);
    expect(
      (await container.read(threadStoreProvider).read(thread.id))?.harnessId,
      'writing',
    );
    expect(
      (await AppPreferencesStore(
        SharedPreferences.getInstance,
      ).load()).lastHarnessIds[_server.id],
      'writing',
    );
  });

  testWidgets('remembered harness is highlighted but only confirmation opens', (
    tester,
  ) async {
    final container = await _mount(tester, remembered: 'coding');
    await _openPicker(tester);
    final row = tester.widget<ListTile>(
      find.byKey(const ValueKey('new-chat-harness-coding')),
    );
    expect(row.selected, isTrue);
    await _expectUnchanged(container, remembered: 'coding');
    await tester.tap(find.text('Start chat'));
    await tester.pumpAndSettle();
    expect(container.read(threadProvider)?.harnessId, 'coding');
    expect(find.text('Chat'), findsOneWidget);
  });

  testWidgets('canceling the picker preserves remembered harness and history', (
    tester,
  ) async {
    final container = await _mount(tester, remembered: 'writing');
    await _openPicker(tester);
    await tester.tap(_inSheet(find.byTooltip('Cancel')));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    await _expectUnchanged(container, remembered: 'writing');
  });

  testWidgets('one harness opens directly even when remembered id is absent', (
    tester,
  ) async {
    final container = await _mount(
      tester,
      remembered: 'removed',
      harnessResponse: (_) async => _json({
        'data': [_catalog.last],
      }),
    );
    await tester.tap(find.text('New chat'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(container.read(threadProvider)?.harnessId, 'coding');
    expect(find.text('Chat'), findsOneWidget);
  });

  testWidgets('initial catalog failure opens a recoverable inline retry', (
    tester,
  ) async {
    var fail = true;
    final container = await _mount(
      tester,
      harnessResponse: (_) async => fail
          ? _json({'error': 'Catalog unavailable'}, 503)
          : _json({'data': _catalog}),
    );
    await _openPicker(tester);
    expect(
      _inSheet(find.textContaining('Catalog unavailable')),
      findsOneWidget,
    );
    await _expectUnchanged(container);
    fail = false;
    await tester.tap(_inSheet(find.text('Retry')));
    await tester.pumpAndSettle();
    expect(_inSheet(find.text('Retry')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('new-chat-harness-research')));
    await tester.pumpAndSettle();
    expect(container.read(threadProvider)?.harnessId, 'research');
  });

  testWidgets('catalog refresh failure stays in picker and can recover', (
    tester,
  ) async {
    var fail = false;
    final container = await _mount(
      tester,
      remembered: 'writing',
      harnessResponse: (_) async => fail
          ? _json({'error': 'Refresh unavailable'}, 503)
          : _json({'data': _catalog}),
    );
    await _openPicker(tester);
    fail = true;
    await tester.tap(_inSheet(find.byTooltip('Reload harnesses')));
    await tester.pumpAndSettle();
    expect(
      _inSheet(find.textContaining('Refresh unavailable')),
      findsOneWidget,
    );
    expect(_inSheet(find.byType(ListTile)), findsNothing);
    await _expectUnchanged(container, remembered: 'writing');
    fail = false;
    await tester.tap(_inSheet(find.text('Retry')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start chat'));
    await tester.pumpAndSettle();
    expect(container.read(threadProvider)?.harnessId, 'writing');
  });

  testWidgets(
    'server change while catalog retry is pending cannot open a chat',
    (tester) async {
      final pending = Completer<http.Response>();
      var retrying = false;
      final container = await _mount(
        tester,
        harnessResponse: (request) async {
          if (request.url.host == 'other.test') {
            return _json({'data': _catalog});
          }
          return retrying
              ? pending.future
              : _json({'error': 'Retry catalog'}, 503);
        },
      );
      await _openPicker(tester);
      retrying = true;
      await tester.tap(_inSheet(find.text('Retry')));
      await tester.pump();
      container.read(selectedServerProvider.notifier).state = _otherServer;
      await tester.pump();
      pending.complete(_json({'data': _catalog}));
      await tester.pumpAndSettle();
      final start = tester.widget<FilledButton>(
        _inSheet(find.byType(FilledButton)),
      );
      expect(start.onPressed, isNull);
      await tester.tap(_inSheet(find.byTooltip('Cancel')));
      await tester.pumpAndSettle();
      await _expectUnchanged(container);
    },
  );

  for (final blocker in ['busy', 'unsaved', 'feed mutation']) {
    testWidgets('$blocker beginning while picker is open blocks selection', (
      tester,
    ) async {
      final container = await _mount(tester);
      await _openPicker(tester);
      if (blocker == 'busy') {
        container.read(taskBusyProvider.notifier).state = true;
      } else if (blocker == 'feed mutation') {
        container.read(feedMutationBusyProvider.notifier).state = true;
      } else {
        final now = DateTime.utc(2026);
        container
            .read(unsavedThreadProvider.notifier)
            .state = ConversationThread(
          id: 'unsaved',
          title: 'Unsaved turn',
          server: _server,
          harnessId: 'research',
          harnessName: 'Research',
          createdAt: now,
          updatedAt: now,
          messages: const [],
        );
      }
      await tester.pump();
      final start = tester.widget<FilledButton>(
        _inSheet(find.byType(FilledButton)),
      );
      expect(start.onPressed, isNull);
      await tester.tap(_inSheet(find.byTooltip('Cancel')));
      await tester.pumpAndSettle();
      await _expectUnchanged(container);
    });
  }

  testWidgets('unmounting origin during picker retry creates no chat', (
    tester,
  ) async {
    final pending = Completer<http.Response>();
    var retrying = false;
    final container = await _mount(
      tester,
      harnessResponse: (_) async =>
          retrying ? pending.future : _json({'error': 'Retry catalog'}, 503),
    );
    await _openPicker(tester);
    retrying = true;
    await tester.tap(_inSheet(find.text('Retry')));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete(_json({'data': _catalog}));
    await tester.pumpAndSettle();
    await _expectUnchanged(container);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Settings explicit harness keeps its direct-open path', (
    tester,
  ) async {
    final container = await _mount(tester, remembered: 'coding');
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    final harness = find.widgetWithText(ListTile, 'Writing');
    await tester.scrollUntilVisible(harness, 300);
    await tester.tap(harness);
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(container.read(threadProvider)?.harnessId, 'writing');
    expect(find.text('Chat'), findsOneWidget);
  });
}
