import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uhp_android/main.dart';

void main() {
  const server = ServerConfig(
    id: 'server',
    name: 'Server',
    baseUrl: 'https://example.test',
  );
  const session = ServerSession(
    id: 'session',
    title: 'Remote title',
    harnessId: 'harness',
    status: 'completed',
    lastResponseId: 'first-response',
  );
  const refreshedSession = ServerSession(
    id: 'session',
    title: 'Updated remote title',
    harnessId: 'harness',
    status: 'completed',
    lastResponseId: 'next-response',
  );
  const turns = [
    SessionTurn(role: 'user', text: 'First question'),
    SessionTurn(role: 'assistant', text: 'First answer'),
  ];
  const next = ResponseRecord(
    prompt: 'Next question',
    output: 'Next answer',
    responseId: 'next-response',
    sessionId: 'session',
  );
  const pending = ResponseRecord(
    prompt: 'Next question',
    output: 'Partial answer',
    responseId: 'next-response',
    sessionId: 'session',
    status: TurnStatus.serverContinuing,
  );
  late Directory documents;
  late ThreadStore store;

  setUp(() async {
    documents = await Directory.systemTemp.createTemp('uhp-thread-management-');
    store = ThreadStore(() async => documents);
  });
  tearDown(() async => documents.delete(recursive: true));

  Future<ConversationThread> link({ServerSession detail = session}) =>
      store.linkServerSession(
        server: server,
        session: detail,
        turns: turns,
        harnessName: 'Harness',
      );

  test(
    'queued management survives restart and stale continuation saves',
    () async {
      final original = await link();
      final changes = await Future.wait([
        store.rename(original.id, '  Local title  '),
        store.setArchived(original.id, true),
      ]);
      expect(changes.last!.title, 'Local title');
      expect(changes.last!.archived, isTrue);
      await store.save(original.appendTurn(next.prompt, next));

      store = ThreadStore(() async => documents);
      final continued = (await store.read(original.id))!;
      expect(continued.title, 'Local title');
      expect(continued.archived, isTrue);
      expect(continued.messages.map((row) => row.text), [
        'First question',
        'First answer',
        next.prompt,
        next.output,
      ]);
      expect(continued.lastResponseId, next.responseId);
      final index = await store.loadIndex();
      expect(index.single.title, 'Local title');
      expect(index.single.archived, isTrue);

      final restored = (await store.setArchived(original.id, false))!;
      expect(restored.title, 'Local title');
      expect(restored.archived, isFalse);
      await store.save(continued);
      store = ThreadStore(() async => documents);
      expect((await store.read(original.id))!.archived, isFalse);
      expect((await store.loadIndex()).single.archived, isFalse);
    },
  );

  test(
    'local title and archive survive remote refresh and settlement',
    () async {
      final original = await link();
      // Choosing the current remote title is still an explicit local rename.
      await store.rename(original.id, session.title);
      await store.setArchived(original.id, true);
      store = ThreadStore(() async => documents);
      final refreshed = await link(detail: refreshedSession);
      expect(refreshed.id, original.id);
      expect(refreshed.title, session.title);
      expect(refreshed.archived, isTrue);

      await store.save(refreshed.appendTurn(pending.prompt, pending));
      await store.rename(original.id, 'Title chosen while paused');
      store = ThreadStore(() async => documents);
      final paused = await link(detail: refreshedSession);
      expect(paused.title, 'Title chosen while paused');
      expect(paused.archived, isTrue);
      expect(paused.messages.last.status, TurnStatus.serverContinuing);
      final settled = (await store.settleResponse(
        original.id,
        next.responseId,
        {
          'id': next.responseId,
          'status': 'completed',
          'output': [
            {
              'role': 'assistant',
              'content': [
                {'text': next.output},
              ],
            },
          ],
        },
      ))!;
      expect(settled.title, 'Title chosen while paused');
      expect(settled.archived, isTrue);
      expect(settled.messages.last.text, next.output);
      expect(settled.messages.last.status, TurnStatus.completed);

      store = ThreadStore(() async => documents);
      final reimported = await link(detail: refreshedSession);
      expect(reimported.title, 'Title chosen while paused');
      expect(reimported.archived, isTrue);
      expect(reimported.messages.last.text, next.output);
      expect(reimported.lastResponseId, next.responseId);
      expect((await store.loadIndex()).single.title, reimported.title);
      expect((await store.loadIndex()).single.archived, isTrue);
    },
  );

  test(
    'deleting linked history removes messages and cannot settle it later',
    () async {
      final original = await link();
      await store.save(original.appendTurn(pending.prompt, pending));
      await store.rename(original.id, 'Local history');
      await store.setArchived(original.id, true);

      final deletion = store.delete(original.id);
      final lateSettlement = store.settleResponse(
        original.id,
        next.responseId,
        {'id': next.responseId, 'status': 'completed'},
      );
      await deletion;
      expect(await lateSettlement, isNull);
      store = ThreadStore(() async => documents);
      expect(await store.read(original.id), isNull);
      expect(await store.loadIndex(), isEmpty);
      expect(await store.continuingThreads(), isEmpty);
      expect(await store.rename(original.id, 'No resurrection'), isNull);
      expect(await store.setArchived(original.id, false), isNull);
      final directory = Directory('${documents.path}/threads');
      expect(directory.listSync().map((file) => file.uri.pathSegments.last), [
        'index.json',
      ]);
      expect(
        jsonDecode(await File('${directory.path}/index.json').readAsString()),
        isEmpty,
      );
    },
  );

  test('legacy thread and index load without management fields', () async {
    final original = await link();
    final legacy = original.toJson()
      ..remove('archived')
      ..remove('localTitleOverride');
    final legacySummary = original.summary.toJson()..remove('archived');
    final directory = Directory('${documents.path}/threads');
    await File('${directory.path}/${original.id}.json')
        .writeAsString(jsonEncode(legacy));
    await File('${directory.path}/index.json')
        .writeAsString(jsonEncode([legacySummary]));

    store = ThreadStore(() async => documents);
    final restored = (await store.read(original.id))!;
    expect(restored.archived, isFalse);
    expect(restored.messages.last.text, 'First answer');
    expect((await store.loadIndex()).single.archived, isFalse);
    final refreshed = await link(detail: refreshedSession);
    expect(refreshed.title, refreshedSession.title);
    expect(refreshed.archived, isFalse);
  });

  test('blank rename rejects without changing persisted metadata', () async {
    final original = await link();
    await store.rename(original.id, 'Chosen title');
    await store.setArchived(original.id, true);
    expect(() => store.rename(original.id, ' \n\t '), throwsArgumentError);
    store = ThreadStore(() async => documents);
    final restored = (await store.read(original.id))!;
    expect(restored.title, 'Chosen title');
    expect(restored.archived, isTrue);
    expect((await store.loadIndex()).single.title, 'Chosen title');
  });
}
