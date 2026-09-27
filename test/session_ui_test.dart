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
  id: 'server',
  name: 'Server',
  baseUrl: 'https://example.test',
  apiKey: 'test-key',
);
const _harness = Harness(
  id: 'h1',
  name: 'Research',
  baseLabel: '',
  defaultModel: 'model-a',
);

ConversationThread _thread({String id = 'local', String status = 'done'}) =>
    ConversationThread(
      id: id,
      title: 'Server conversation',
      server: _server,
      harnessId: 'h1',
      harnessName: 'Research',
      model: 'model-a',
      serverSessionId: 's1',
      serverHarnessId: 'h1',
      serverLastResponseId: 'r1',
      serverSessionStatus: status,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      messages: const [],
    );

class _SessionSurface extends ConsumerWidget {
  const _SessionSurface();
  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      ref.watch(selectedTabProvider) == AppTab.tasks
      ? const TasksScreen()
      : const SessionsScreen();
}

void main() {
  Future<ProviderContainer> mount(
    WidgetTester tester,
    http.Client client,
    Widget child,
  ) async {
    SharedPreferences.setMockInitialValues({
      ServerStore.key: jsonEncode([_server.toJson()]),
    });
    final directory = await tester.runAsync(
      () => Directory.systemTemp.createTemp('session-ui-'),
    );
    // ThreadStore creates its serialization future in the constructor. Keep
    // that queue in the same real async zone as the disk operations below.
    final store = await tester.runAsync(
      () async => ThreadStore(() async => directory!),
    );
    final container = ProviderContainer(
      overrides: [
        httpClientProvider.overrideWithValue(client),
        threadStoreProvider.overrideWithValue(store!),
      ],
    );
    await tester.runAsync(() => container.read(serversProvider.future));
    container.read(selectedServerProvider.notifier).state = _server;
    container.read(selectedHarnessProvider.notifier).state = _harness;
    addTearDown(() async {
      container.dispose();
      client.close();
      await tester.runAsync(() => directory!.delete(recursive: true));
    });
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
    return container;
  }

  Future<void> waitForThreadChange(
    WidgetTester tester,
    ProviderContainer container,
    Future<void> Function() action,
  ) async {
    // Start the action and await its I/O in the real async zone. Pumping fake
    // frames cannot make filesystem work finish, regardless of runner speed.
    await tester.runAsync(() async {
      final changed = Completer<void>();
      final idle = Completer<void>();
      final threadSubscription = container.listen(threadProvider, (_, next) {
        if (next != null && !changed.isCompleted) changed.complete();
      });
      final busySubscription = container.listen(taskBusyProvider, (_, busy) {
        if (!busy && !idle.isCompleted) idle.complete();
      });
      try {
        await action();
        await changed.future;
        // Submissions publish the thread before its save finishes. Session
        // imports instead publish after saving, without setting taskBusy.
        if (container.read(taskBusyProvider)) await idle.future;
      } finally {
        threadSubscription.close();
        busySubscription.close();
      }
    });
    expect(container.read(taskBusyProvider), isFalse);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'running linked session disables send until explicit server refresh',
    (tester) async {
      final client = MockClient((request) async => http.Response('{}', 200));
      final container = await mount(tester, client, const TasksScreen());
      container.read(threadProvider.notifier).state = _thread(
        status: 'in_progress',
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Prompt'))
            .enabled,
        isFalse,
      );
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Continue'))
            .onPressed,
        isNull,
      );
      expect(find.textContaining('running on the server'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(
              find.widgetWithText(TextButton, 'Refresh server session'),
            )
            .onPressed,
        isNotNull,
      );
    },
  );

  testWidgets(
    'opening and refreshing imports server transcript without duplicating local links',
    (tester) async {
      var status = 'running';
      var answer = 'Partial server answer';
      Map<String, Object> session() => {
        'id': 's1',
        'title': 'Remote discussion',
        'harnessId': 'h1',
        'model': 'model-a',
        'status': status,
        'lastResponseId': 'r1',
      };
      final client = MockClient((request) async {
        final body = switch (request.url.path) {
          '/api/harness/v1/harnesses' => {
            'data': [
              {'id': 'h1', 'name': 'Research'},
            ],
          },
          '/api/harness/v1/sessions' => {
            'sessions': [session()],
          },
          '/api/harness/v1/sessions/s1' => session(),
          '/api/harness/v1/sessions/s1/turns' => {
            'turns': [
              {'role': 'user', 'text': 'Question'},
              {'role': 'assistant', 'text': answer},
            ],
          },
          _ => throw StateError('Unexpected ${request.url}'),
        };
        return http.Response(jsonEncode(body), 200);
      });
      final container = await mount(tester, client, const _SessionSurface());
      await waitForThreadChange(
        tester,
        container,
        () => tester.tap(find.text('Remote discussion')),
      );
      expect(find.text('Partial server answer'), findsOneWidget);
      final originalId = container.read(threadProvider)!.id;
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Prompt'))
            .enabled,
        isFalse,
      );
      status = 'done';
      answer = 'Complete server answer';
      await waitForThreadChange(
        tester,
        container,
        () => tester.tap(find.text('Refresh server session')),
      );
      expect(container.read(threadProvider)!.id, originalId);
      expect(find.text('Complete server answer'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Prompt'))
            .enabled,
        isTrue,
      );
      final index = await tester.runAsync(
        () => container.read(threadStoreProvider).loadIndex(),
      );
      expect(index!.single.id, originalId);
    },
  );

  testWidgets(
    'model picker selects an override and resets for another conversation',
    (tester) async {
      final client = MockClient((request) async {
        if (request.url.path == '/api/harness/v1/harnesses/h1/models') {
          return http.Response('{}', 404);
        }
        if (request.url.path == '/api/harness/v1/models') {
          return http.Response('{"models":["model-a","model-b"]}', 200);
        }
        throw StateError('Unexpected ${request.url}');
      });
      final container = await mount(tester, client, const TasksScreen());
      container.read(threadProvider.notifier).state = _thread();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Model: Harness default'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('model-b').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use model'));
      await tester.pumpAndSettle();
      expect(find.text('Model: model-b'), findsOneWidget);
      container.read(threadProvider.notifier).state = _thread(id: 'another');
      await tester.pumpAndSettle();
      expect(find.text('Model: Harness default'), findsOneWidget);
      expect(find.text('Model: model-b'), findsNothing);
    },
  );

  testWidgets('selected model is sent and Default omits the model override', (
    tester,
  ) async {
    final requests = <Map<String, dynamic>>[];
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/models')) {
        return http.Response('{"models":["model-b"]}', 200);
      }
      requests.add(jsonDecode(request.body) as Map<String, dynamic>);
      final response = {
        'id': 'response-${requests.length}',
        'output': [
          {
            'role': 'assistant',
            'content': [
              {'text': 'Answer'},
            ],
          },
        ],
      };
      return http.Response(
        'data: ${jsonEncode({'type': 'response.completed', 'response': response})}\n\n',
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    });
    final container = await mount(tester, client, const TasksScreen());
    await tester.tap(find.text('Model: Harness default'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('model-b').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use model'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Prompt'),
      'Use the selected model',
    );
    await waitForThreadChange(
      tester,
      container,
      () => tester.tap(find.text('Run task')),
    );
    expect(requests.single['model'], 'model-b');
    await tester.tap(find.text('New task'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Prompt'),
      'Use the default model',
    );
    await waitForThreadChange(
      tester,
      container,
      () => tester.tap(find.text('Run task')),
    );
    expect(requests.last.containsKey('model'), isFalse);
  });

  testWidgets('server changes discard a delayed session list', (tester) async {
    final oldSessions = Completer<http.Response>();
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/harnesses')) {
        return http.Response('{"data":[]}', 200);
      }
      if (request.url.host == 'example.test') return oldSessions.future;
      return http.Response(
        '{"sessions":[{"id":"new","title":"New server session"}]}',
        200,
      );
    });
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer(
      overrides: [httpClientProvider.overrideWithValue(client)],
    );
    addTearDown(container.dispose);
    addTearDown(client.close);
    container.read(selectedServerProvider.notifier).state = _server;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: SessionsScreen())),
      ),
    );
    await tester.pump();
    container.read(selectedServerProvider.notifier).state = const ServerConfig(
      id: 'other',
      name: 'Other',
      baseUrl: 'https://other.test',
      apiKey: 'key',
    );
    await tester.pumpAndSettle();
    oldSessions.complete(
      http.Response(
        '{"sessions":[{"id":"old","title":"Old server session"}]}',
        200,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('New server session'), findsOneWidget);
    expect(find.text('Old server session'), findsNothing);
  });
}
