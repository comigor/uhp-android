import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uhp_android/main.dart';

const _server = ServerConfig(
  id: 'profile',
  name: 'Server',
  baseUrl: 'https://example.test',
  apiKey: 'fresh-key',
  accessTokenId: 'edge-id',
  accessToken: 'edge-token',
);
const _harness = Harness(
  id: 'h',
  name: 'Harness',
  baseLabel: '',
  defaultModel: '',
);

class _Client extends http.BaseClient {
  _Client(this.handle);
  final Future<http.StreamedResponse> Function(http.BaseRequest) handle;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handle(request);
}

http.StreamedResponse _json(Map<String, dynamic> record) =>
    http.StreamedResponse(Stream.value(utf8.encode(jsonEncode(record))), 200);

Map<String, dynamic> _completed(String id) => {
  'id': id,
  'status': 'completed',
  'output': [
    null,
    42,
    {'type': 'future_item', 'content': 'unknown'},
    {
      'type': 'message',
      'role': 'assistant',
      'content': [
        null,
        {'type': 'future_content'},
        {'type': 'output_text', 'text': 'Final answer'},
      ],
    },
  ],
  'usage': {'input_tokens': 2, 'output_tokens': 3, 'total_tokens': 5},
};

class _Alarm implements Timer {
  _Alarm(this.duration, this.callback);
  final Duration duration;
  final void Function() callback;
  bool _active = true;
  int _tick = 0;
  @override
  bool get isActive => _active;
  @override
  int get tick => _tick;
  @override
  void cancel() => _active = false;
  void fire() {
    if (!_active) return;
    _active = false;
    _tick++;
    callback();
  }
}

class _Controller extends ServerContinuationController {
  _Controller(super.ref, List<_Alarm> alarms)
    : super(
        schedule: (duration, callback) {
          final alarm = _Alarm(duration, callback);
          alarms.add(alarm);
          return alarm;
        },
      );
  Future<void> lastCheck = Future<void>.value();
  @override
  Future<void> checkNow() => lastCheck = super.checkNow();
}

class _Fixture {
  _Fixture(
    this.directory,
    this.store,
    this.container,
    this.controller,
    this.alarms,
  );
  final Directory directory;
  final ThreadStore store;
  final ProviderContainer container;
  final _Controller controller;
  final List<_Alarm> alarms;

  static Future<_Fixture> create(http.Client client) async {
    SharedPreferences.setMockInitialValues({
      ServerStore.key: jsonEncode([_server.toJson()]),
    });
    final directory = await Directory.systemTemp.createTemp(
      'server-continuation-',
    );
    final store = ThreadStore(() async => directory);
    final alarms = <_Alarm>[];
    final container = ProviderContainer(
      overrides: [
        httpClientProvider.overrideWithValue(client),
        threadStoreProvider.overrideWithValue(store),
        serverContinuationProvider.overrideWith((ref) {
          final controller = _Controller(ref, alarms);
          ref.onDispose(controller.dispose);
          return controller;
        }),
      ],
    );
    await container.read(serversProvider.future);
    container.read(selectedServerProvider.notifier).state = _server;
    container.read(selectedHarnessProvider.notifier).state = _harness;
    container.read(appDestinationProvider.notifier).state = AppDestination.chat;
    return _Fixture(
      directory,
      store,
      container,
      container.read(serverContinuationProvider) as _Controller,
      alarms,
    );
  }

  Future<ConversationThread> pending(String id) async {
    final now = DateTime.utc(2026, 9, 27);
    final thread = ConversationThread(
      id: 'thread-$id',
      title: 'Question',
      server: _server,
      harnessId: 'h',
      harnessName: 'Harness',
      serverSessionId: 'session-$id',
      serverHarnessId: 'h',
      serverLastResponseId: 'previous',
      serverSessionStatus: 'running',
      createdAt: now,
      updatedAt: now,
      messages: [
        ThreadMessage(role: 'user', text: 'Question', createdAt: now),
        ThreadMessage(
          role: 'assistant',
          text: 'Partial answer',
          responseId: id,
          sessionId: 'session-$id',
          status: TurnStatus.serverContinuing,
          createdAt: now,
        ),
      ],
    );
    await store.save(thread);
    container.read(threadProvider.notifier).state = thread;
    return thread;
  }

  Future<void> dispose() async {
    container.dispose();
    await directory.delete(recursive: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'lifecycle pause persists partial identity; resume renders final record',
    (tester) async {
      // Mount while inactive: frames are enabled, but recovery has not resumed.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      final bytes = (await tester.runAsync(
        () async => StreamController<List<int>>(),
      ))!;
      var closed = false;
      bytes.onCancel = () => closed = true;
      final client = _Client((request) async {
        if (request.method == 'GET') {
          expect(request.url.path, '/api/harness/v1/responses/response-1');
          expect(request.headers['Authorization'], 'Bearer fresh-key');
          expect(request.headers['P-Access-Token'], 'edge-token');
          return _json(_completed('response-1'));
        }
        expect(request.url.path, '/api/harness/v1/responses');
        return http.StreamedResponse(
          bytes.stream,
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });
      final fixture = (await tester.runAsync(() => _Fixture.create(client)))!;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: fixture.container,
          child: const UhpApp(),
        ),
      );
      late Future<void> submission;
      await tester.runAsync(() async {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await fixture.controller.lastCheck;
        final partial = Completer<void>();
        final subscription = fixture.container.listen(liveTurnProvider, (
          _,
          next,
        ) {
          if (next?.progress.text == 'Partial answer' && !partial.isCompleted) {
            partial.complete();
          }
        });
        submission = fixture.container
            .read(taskRunnerProvider)
            .submit('Question');
        bytes.add(
          utf8.encode(
            'data: ${jsonEncode({
              'type': 'response.created',
              'response': {
                'id': 'response-1',
                'metadata': {'session_id': 'session-1'},
              },
            })}\n\n',
          ),
        );
        bytes.add(
          utf8.encode(
            'data: {"type":"response.output_text.delta","delta":"Partial answer"}\n\n',
          ),
        );
        await partial.future;
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await submission;
        subscription.close();
        expect(closed, isTrue);
        final thread = fixture.container.read(threadProvider)!;
        final persisted = (await ThreadStore(() async => fixture.directory)
            .read(thread.id))!;
        expect(persisted.messages.last.status, TurnStatus.serverContinuing);
        expect(persisted.messages.last.responseId, 'response-1');
        expect(persisted.messages.last.text, 'Partial answer');
        expect(
          persisted.messages.last.createdAt,
          thread.messages.last.createdAt,
        );
        expect(persisted.updatedAt, thread.updatedAt);
        expect(fixture.alarms, isEmpty);
      });
      await tester.pumpAndSettle();
      expect(find.text('Partial answer', findRichText: true), findsOneWidget);
      expect(find.text('Server still working…'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Prompt'))
            .enabled,
        isFalse,
      );
      await tester.runAsync(() async {
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await fixture.controller.lastCheck;
        final thread = fixture.container.read(threadProvider)!;
        final persisted = (await fixture.store.read(thread.id))!;
        expect(persisted.messages.last.status, TurnStatus.completed);
        expect(persisted.lastResponseId, 'response-1');
        expect(persisted.messages.last.usage?.totalTokens, 5);
        expect(fixture.alarms, isEmpty);
      });
      await tester.pumpAndSettle();
      expect(find.text('Final answer', findRichText: true), findsOneWidget);
      expect(find.text('Partial answer', findRichText: true), findsNothing);
      expect(
        find.text('input: 2 · output: 3 · total: 5 tokens'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Prompt'))
            .enabled,
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await fixture.dispose();
        await bytes.close();
      });
      client.close();
    },
  );

  test('resume discovers persisted turns; five-second polling stops once all settle', () async {
    final requests = <String>[];
    final client = _Client((request) async {
      final id = request.url.pathSegments.last;
      requests.add(id);
      return _json(
        id == 'second' && requests.where((value) => value == id).length == 1
            ? {'id': id, 'status': 'running'}
            : _completed(id),
      );
    });
    final fixture = await _Fixture.create(client);
    addTearDown(fixture.dispose);
    addTearDown(client.close);
    final first = await fixture.pending('first');
    final second = await fixture.pending('second');
    fixture.container.read(threadProvider.notifier).state = null;
    await fixture.controller.resume();
    expect(requests.toSet(), {'first', 'second'});
    expect((await fixture.store.read(first.id))!.lastResponseId, 'first');
    expect((await fixture.store.read(second.id))!.hasServerContinuing, isTrue);
    expect(fixture.alarms.single.duration, const Duration(seconds: 5));
    fixture.alarms.single.fire();
    await fixture.controller.lastCheck;
    expect(requests.where((id) => id == 'second'), hasLength(2));
    expect((await fixture.store.read(second.id))!.lastResponseId, 'second');
    for (final alarm in fixture.alarms) {
      alarm.fire();
    }
    expect(requests, hasLength(3));
    expect(fixture.alarms.where((alarm) => alarm.isActive), isEmpty);
  });

  test('pause cancels scheduled poll and resume checks immediately', () async {
    var requests = 0;
    final client = _Client((request) async {
      requests++;
      return _json({'id': 'r', 'status': 'running'});
    });
    final fixture = await _Fixture.create(client);
    addTearDown(fixture.dispose);
    addTearDown(client.close);
    await fixture.pending('r');
    await fixture.controller.resume();
    fixture.controller.pause();
    fixture.alarms.single.fire();
    await fixture.controller.checkNow();
    expect(requests, 1);
    expect(fixture.alarms.where((alarm) => alarm.isActive), isEmpty);
    await fixture.controller.resume();
    expect(requests, 2);
    fixture.controller.pause();
  });

  test('pause aborts active fetch; late response cannot settle after a new generation', () async {
    final started = Completer<http.AbortableRequest>();
    final headers = Completer<http.StreamedResponse>();
    final cancelled = Completer<void>();
    final lateBody = StreamController<List<int>>(onCancel: cancelled.complete);
    var calls = 0;
    final client = _Client((request) async {
      calls++;
      if (calls == 1) {
        started.complete(request as http.AbortableRequest);
        return headers.future;
      }
      return _json(_completed('r'));
    });
    final fixture = await _Fixture.create(client);
    addTearDown(fixture.dispose);
    addTearDown(client.close);
    final thread = await fixture.pending('r');
    final oldCheck = fixture.controller.resume();
    final request = await started.future;
    fixture.controller.pause();
    await request.abortTrigger;
    await oldCheck;
    expect(fixture.alarms, isEmpty);
    expect((await fixture.store.read(thread.id))!.hasServerContinuing, isTrue);
    await fixture.controller.resume();
    headers.complete(http.StreamedResponse(lateBody.stream, 200));
    await cancelled.future;
    expect(
      (await fixture.store.read(thread.id))!.messages.last.text,
      'Final answer',
    );
    expect(fixture.alarms, isEmpty);
    await lateBody.close();
  });

  testWidgets('composer guard prevents submit and Check now bypasses cadence', (
    tester,
  ) async {
    var calls = 0;
    final client = _Client((request) async {
      expect(request.method, 'GET');
      calls++;
      return _json(
        calls == 1 ? {'id': 'r', 'status': 'running'} : _completed('r'),
      );
    });
    final fixture = (await tester.runAsync(() => _Fixture.create(client)))!;
    await tester.runAsync(() async {
      await fixture.pending('r');
      await fixture.controller.resume();
      await expectLater(
        fixture.container.read(taskRunnerProvider).submit('Forbidden'),
        throwsA(isA<AppError>()),
      );
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: fixture.container,
        child: const MaterialApp(home: Scaffold(body: TasksScreen())),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Continue'))
          .onPressed,
      isNull,
    );
    expect(
      find.text('Waiting for previous turn to finish on server'),
      findsOneWidget,
    );
    await tester.runAsync(() async {
      await tester.tap(find.text('Check now'));
      await fixture.controller.lastCheck;
    });
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('Final answer', findRichText: true), findsOneWidget);
    expect(fixture.alarms.where((alarm) => alarm.isActive), isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(fixture.dispose);
    client.close();
  });

  test('failed, error, incomplete and cancelled records settle without discarding partials', () async {
    for (final status in ['failed', 'error', 'incomplete', 'cancelled']) {
      final client = _Client(
        (request) async => _json({
          'id': 'r',
          'status': status,
          'error': {'message': 'Server detail'},
        }),
      );
      final fixture = await _Fixture.create(client);
      try {
        final thread = await fixture.pending('r');
        await fixture.controller.resume();
        final saved = (await fixture.store.read(thread.id))!;
        expect(
          saved.messages.last.status,
          status == 'cancelled' ? TurnStatus.cancelled : TurnStatus.failed,
        );
        expect(saved.messages.last.text, 'Partial answer');
        if (status != 'cancelled') {
          expect(saved.messages.last.error, isNotEmpty);
        }
        expect(saved.hasServerContinuing, isFalse);
        expect(fixture.alarms, isEmpty);
      } finally {
        await fixture.dispose();
        client.close();
      }
    }
  });
}
