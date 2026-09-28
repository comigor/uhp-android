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
  id: 'server',
  name: 'Server',
  baseUrl: 'https://example.test',
  apiKey: 'test-key',
);
const _harness = Harness(
  id: 'harness',
  name: 'Harness',
  baseLabel: '',
  defaultModel: '',
);
const _session = ServerSession(
  id: 'session',
  title: 'Linked chat',
  harnessId: 'harness',
  status: 'completed',
  lastResponseId: 'previous',
);

ConversationThread _thread(String id, {bool linked = false}) =>
    ConversationThread(
      id: id,
      title: 'Chat $id',
      server: _server,
      harnessId: _harness.id,
      harnessName: _harness.name,
      serverSessionId: linked ? _session.id : null,
      serverHarnessId: linked ? _harness.id : null,
      serverLastResponseId: linked ? 'previous' : null,
      serverSessionStatus: linked ? 'completed' : null,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      messages: const [],
    );

class _MemoryDraftStore extends ThreadStore {
  _MemoryDraftStore() : super(() async => throw StateError('No disk access'));
  final drafts = <String, String>{};
  final initialThreads = <String, ConversationThread>{};
  final delayedReads = <String, Completer<String>>{};
  Completer<void>? clearStarted;
  Completer<void>? allowClear;

  @override
  Future<String> readDraft(String id) async => delayedReads[id] == null
      ? drafts[id] ?? ''
      : await delayedReads[id]!.future;

  @override
  Future<void> saveDraft(
    String id,
    String text, {
    ConversationThread? initialThread,
  }) async {
    if (text.isEmpty && allowClear != null) {
      clearStarted?.complete();
      await allowClear!.future;
    }
    drafts[id] = text;
    if (initialThread != null) initialThreads[id] = initialThread;
  }
}

class _TurnClient extends http.BaseClient {
  _TurnClient(this.respond);
  final Future<http.StreamedResponse> Function(http.BaseRequest) respond;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      respond(request);
}

final _prompt = find.widgetWithText(TextField, 'Prompt');
String _composer(WidgetTester tester) =>
    tester.widget<TextField>(_prompt).controller!.text;

Future<ProviderContainer> _mount(
  WidgetTester tester,
  _MemoryDraftStore store, {
  ConversationThread? thread,
}) async {
  SharedPreferences.setMockInitialValues({});
  final container = ProviderContainer(
    overrides: [threadStoreProvider.overrideWithValue(store)],
  );
  container.read(selectedServerProvider.notifier).state = _server;
  container.read(selectedHarnessProvider.notifier).state = _harness;
  container.read(threadProvider.notifier).state = thread;
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        scaffoldMessengerKey: container.read(appScaffoldMessengerKeyProvider),
        home: const Scaffold(body: TasksScreen()),
      ),
    ),
  );
  await tester.pump();
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'local and linked drafts survive restart and stale transcript updates',
    () async {
      final directory = await Directory.systemTemp.createTemp('uhp-drafts-');
      addTearDown(() => directory.delete(recursive: true));
      final store = ThreadStore(() async => directory);
      final local = _thread('local');
      await store.save(local);
      final linked = await store.linkServerSession(
        server: _server,
        session: _session,
        turns: const [],
        harnessName: _harness.name,
      );
      await store.saveDraft(local.id, 'local unsent');
      await store.saveDraft(linked.id, 'linked unsent');
      await store.rename(linked.id, 'Renamed');
      await store.linkServerSession(
        server: _server,
        session: _session,
        turns: const [SessionTurn(role: 'assistant', text: 'Remote answer')],
        harnessName: _harness.name,
      );
      await store.save(
        linked.appendTurn(
          'Question',
          const ResponseRecord(
            prompt: 'Question',
            output: 'Answer',
            responseId: 'next',
            sessionId: 'session',
          ),
        ),
      );
      final restarted = ThreadStore(() async => directory);
      expect(await restarted.readDraft(local.id), 'local unsent');
      expect(await restarted.readDraft(linked.id), 'linked unsent');
      expect((await restarted.read(linked.id))!.title, 'Renamed');
      await restarted.delete(linked.id);
      await restarted.save(linked);
      expect(await ThreadStore(() async => directory).readDraft(linked.id), '');
      expect(await restarted.readDraft(local.id), 'local unsent');
    },
  );

  test('new local draft identity is durable before the first send', () async {
    final directory = await Directory.systemTemp.createTemp('uhp-new-draft-');
    addTearDown(() => directory.delete(recursive: true));
    final store = ThreadStore(() async => directory);
    final first = _thread('first');
    final second = _thread('second');
    await store.saveDraft(first.id, 'one', initialThread: first);
    await store.saveDraft(second.id, 'two', initialThread: second);
    final restarted = ThreadStore(() async => directory);
    expect(
      (await restarted.loadIndex()).map((row) => row.id),
      containsAll(['first', 'second']),
    );
    expect(await restarted.readDraft('first'), 'one');
    expect(await restarted.readDraft('second'), 'two');
  });

  testWidgets(
    'composer debounces, switches independently, and flushes on dispose',
    (tester) async {
      final store = _MemoryDraftStore();
      final container = await _mount(tester, store, thread: _thread('local'));
      await tester.enterText(_prompt, 'first');
      await tester.pump(const Duration(milliseconds: 200));
      expect(store.drafts['local'], isNull);
      await tester.enterText(_prompt, 'latest');
      await tester.pump(const Duration(milliseconds: 274));
      expect(store.drafts['local'], isNull);
      await tester.pump(const Duration(milliseconds: 1));
      expect(store.drafts['local'], 'latest');
      await tester.enterText(_prompt, 'switch flush');
      container.read(threadProvider.notifier).state = _thread(
        'linked',
        linked: true,
      );
      await tester.pump();
      expect(store.drafts['local'], 'switch flush');
      expect(_composer(tester), '');
      await tester.enterText(_prompt, 'linked draft');
      container.read(threadProvider.notifier).state = _thread('local');
      await tester.pump();
      expect(_composer(tester), 'switch flush');
      expect(store.drafts['linked'], 'linked draft');
      await tester.enterText(_prompt, 'dispose flush');
      await tester.pumpWidget(const SizedBox());
      expect(store.drafts['local'], 'dispose flush');
    },
  );

  testWidgets(
    'late hydration cannot replace typing or leak into another chat',
    (tester) async {
      final store = _MemoryDraftStore();
      final localRead = Completer<String>();
      final linkedRead = Completer<String>();
      store.delayedReads['local'] = localRead;
      store.delayedReads['linked'] = linkedRead;
      final container = await _mount(tester, store, thread: _thread('local'));
      await tester.enterText(_prompt, 'new typing');
      localRead.complete('old persisted');
      await tester.pump();
      expect(_composer(tester), 'new typing');
      container.read(threadProvider.notifier).state = _thread(
        'linked',
        linked: true,
      );
      await tester.pump();
      container.read(threadProvider.notifier).state = _thread('local');
      await tester.pump();
      linkedRead.complete('linked persisted');
      await tester.pump();
      expect(_composer(tester), 'new typing');
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'New task gets separate identities and lifecycle flushes without waiting',
    (tester) async {
      final store = _MemoryDraftStore();
      await _mount(tester, store);
      await tester.enterText(_prompt, 'first new chat');
      await tester.tap(find.text('New task'));
      await tester.pump();
      expect(_composer(tester), '');
      await tester.enterText(_prompt, 'second new chat');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();
      expect(
        store.drafts.values,
        containsAll(['first new chat', 'second new chat']),
      );
      expect(store.initialThreads.keys.toSet().length, 2);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test(
    'accepted clear cannot clear a newer draft or another conversation',
    () async {
      final store = _MemoryDraftStore();
      final drafts = ComposerDraftController(
        store: store,
        onHydrated: (_) {},
        onError: (error) => fail('$error'),
      );
      drafts.bind(_thread('one'));
      drafts.update('sent');
      final revision = drafts.revision;
      drafts.update('newer');
      await drafts.clearAccepted('one', revision);
      await drafts.flush();
      expect(store.drafts['one'], 'newer');
      final latest = drafts.revision;
      drafts.bind(_thread('two'));
      drafts.update('other');
      final rollback = await drafts.clearAccepted('one', latest);
      await drafts.flush();
      expect(store.drafts['one'], '');
      expect(store.drafts['two'], 'other');
      drafts.bind(_thread('one'));
      drafts.update('typed after acceptance');
      await rollback!();
      await drafts.flush();
      expect(store.drafts['one'], 'typed after acceptance');
      expect(store.drafts['two'], 'other');
      drafts.dispose();
    },
  );

  test('auth rejection leaves the submitted draft intact', () async {
    final store = _MemoryDraftStore();
    final drafts = ComposerDraftController(
      store: store,
      onHydrated: (_) {},
      onError: (error) => fail('$error'),
    );
    final thread = _thread('chat');
    drafts.bind(thread);
    drafts.update('keep without credentials');
    await drafts.flush();
    final container = ProviderContainer(
      overrides: [threadStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    container.read(selectedServerProvider.notifier).state = ServerConfig(
      id: _server.id,
      name: _server.name,
      baseUrl: _server.baseUrl,
    );
    container.read(selectedHarnessProvider.notifier).state = _harness;
    await expectLater(
      container
          .read(taskRunnerProvider)
          .submit(
            'keep without credentials',
            onAccepted: () => drafts.clearAccepted(thread.id, drafts.revision),
          ),
      throwsA(isA<AppError>()),
    );
    expect(store.drafts[thread.id], 'keep without credentials');
    drafts.dispose();
  });

  test(
    'backgrounding during the durable clear restores an undispatched draft',
    () async {
      SharedPreferences.setMockInitialValues({
        ServerStore.key: jsonEncode([_server.toJson()]),
      });
      final store = _MemoryDraftStore();
      final drafts = ComposerDraftController(
        store: store,
        onHydrated: (_) {},
        onError: (error) => fail('$error'),
      );
      final thread = _thread('chat');
      drafts.bind(thread);
      drafts.update('not dispatched');
      await drafts.flush();
      store.clearStarted = Completer<void>();
      store.allowClear = Completer<void>();
      final client = _TurnClient(
        (_) async => throw StateError('Must not dispatch'),
      );
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
      await container.read(serversProvider.future);
      container.read(threadProvider.notifier).state = thread;
      final runner = container.read(taskRunnerProvider);
      final submission = runner.submit(
        'not dispatched',
        onAccepted: () => drafts.clearAccepted(thread.id, drafts.revision),
      );
      final rejected = expectLater(submission, throwsA(isA<AppError>()));
      await store.clearStarted!.future;
      final stopped = expectLater(
        runner.background(),
        throwsA(isA<AppError>()),
      );
      store.allowClear!.complete();
      await rejected;
      await stopped;
      expect(store.drafts[thread.id], 'not dispatched');
      expect(container.read(threadProvider)!.messages, isEmpty);
      drafts.dispose();
    },
  );

  for (final linked in [false, true]) {
    test(
      '${linked ? 'linked' : 'local'} rejected preflight retains draft; dispatch clears before stream ends',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'uhp-send-draft-',
        );
        final store = ThreadStore(() async => directory);
        final thread = _thread('chat', linked: linked);
        await store.save(thread);
        SharedPreferences.setMockInitialValues({
          ServerStore.key: jsonEncode([_server.toJson()]),
        });
        var reject = true;
        var dispatched = false;
        final sent = Completer<void>();
        final stream = StreamController<List<int>>();
        final client = _TurnClient((request) async {
          if (request.method == 'GET') {
            return http.StreamedResponse(
              Stream.value(
                utf8.encode(
                  jsonEncode({
                    'id': 'session',
                    'title': 'Linked chat',
                    'harness_id': 'harness',
                    'status': reject ? 'running' : 'completed',
                    'last_response_id': 'previous',
                  }),
                ),
              ),
              200,
            );
          }
          dispatched = true;
          sent.complete();
          return http.StreamedResponse(
            stream.stream,
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        });
        final container = ProviderContainer(
          overrides: [
            httpClientProvider.overrideWithValue(client),
            threadStoreProvider.overrideWithValue(store),
          ],
        );
        addTearDown(() async {
          container.dispose();
          client.close();
          await directory.delete(recursive: true);
        });
        await container.read(serversProvider.future);
        container.read(threadProvider.notifier).state = thread;
        final drafts = ComposerDraftController(
          store: store,
          onHydrated: (_) {},
          onError: (error) => fail('$error'),
        );
        drafts.bind(thread);
        drafts.update('keep me');
        await drafts.flush();
        final revision = drafts.revision;
        final runner = container.read(taskRunnerProvider);
        // A local empty prompt fails validation; a linked prompt fails the fresh
        // server-session preflight. Neither may erase the persisted draft.
        await expectLater(
          runner.submit(
            linked ? 'keep me' : '',
            onAccepted: () => drafts.clearAccepted(thread.id, revision),
          ),
          throwsA(isA<AppError>()),
        );
        expect(dispatched, isFalse);
        expect(await store.readDraft(thread.id), 'keep me');
        reject = false;
        final submission = runner.submit(
          'keep me',
          onAccepted: () => drafts.clearAccepted(thread.id, revision),
        );
        await sent.future;
        expect(
          await ThreadStore(() async => directory).readDraft(thread.id),
          '',
        );
        expect(container.read(taskBusyProvider), isTrue);
        stream.add(
          utf8.encode(
            'data: ${jsonEncode({
              'type': 'response.completed',
              'response': {'id': 'next', 'status': 'completed', 'output': []},
            })}\n\n',
          ),
        );
        await stream.close();
        await submission;
        drafts.dispose();
      },
    );
  }
}
