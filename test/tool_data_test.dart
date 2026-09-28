import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:uhp_android/main.dart';

const _server = ServerConfig(
  id: 'server',
  name: 'Server',
  baseUrl: 'https://example.test',
  apiKey: 'fixture',
);
const _session = ServerSession(id: 'session', harnessId: 'harness');
const _tool = ToolCall(name: 'read', args: ' {"path":"notes.txt"}\n');
const _attachment = MessageAttachment(
  id: 'file_1',
  name: 'notes.txt',
  bytes: 4,
  mediaType: 'text/plain',
);
final _created = DateTime.utc(2026, 1, 1);

ConversationThread _thread({
  String id = 'thread',
  TurnStatus status = TurnStatus.completed,
}) => ConversationThread(
  id: id,
  title: 'Local title',
  localTitleOverride: 'Local title',
  archived: true,
  server: _server,
  harnessId: 'harness',
  harnessName: 'Harness',
  serverSessionId: 'session',
  createdAt: _created,
  updatedAt: _created,
  messages: [
    ThreadMessage(
      role: 'user',
      text: 'First question\r\nSecond line',
      createdAt: _created,
      attachments: const [_attachment],
    ),
    ThreadMessage(
      role: 'assistant',
      text: 'Answer',
      responseId: 'response',
      sessionId: 'session',
      status: status,
      error: 'Retained metadata',
      usage: const TokenUsage(outputTokens: 7),
      createdAt: _created,
      tools: const [_tool],
    ),
  ],
);

void main() {
  test(
    'turn parser preserves exact string arguments across supported shapes',
    () async {
      const args = '  {"path":"notes.txt", "text":"é"}\n';
      const tools = [
        {'name': 'read', 'arguments': args},
        {'name': 'bash', 'arguments': 'not JSON\n  '},
      ];
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'turns': [
              {'user': 'Question', 'assistant': 'Answer', 'tools': tools},
              {
                'input': 'Legacy question',
                'output': 'Legacy answer',
                'tools': tools,
              },
              {'role': 'assistant', 'content': 'Role answer', 'tools': tools},
              {'role': 'assistant', 'text': 'No tools'},
              {'user': 'Pending', 'assistant': null, 'tools': []},
              {
                'role': 'assistant',
                'text': 'Future shape',
                'tools': [
                  {
                    'name': 'read',
                    'arguments': {'path': 'not-a-string'},
                  },
                  {'name': 'read', 'result': 'Not arguments'},
                  {'name': 5, 'arguments': '{}'},
                  null,
                ],
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      );
      addTearDown(client.close);
      final turns = await UhpService(client)
          .fetchSessionTurns(_server, 'session');
      expect(turns.map((turn) => (turn.role, turn.text)), [
        ('user', 'Question'),
        ('assistant', 'Answer'),
        ('user', 'Legacy question'),
        ('assistant', 'Legacy answer'),
        ('assistant', 'Role answer'),
        ('assistant', 'No tools'),
        ('user', 'Pending'),
        ('assistant', 'Future shape'),
      ]);
      for (final index in [1, 3, 4]) {
        expect(turns[index].tools.map((tool) => (tool.name, tool.args)), [
          ('read', args),
          ('bash', 'not JSON\n  '),
        ]);
      }
      for (final index in [0, 2, 5, 6, 7]) {
        expect(turns[index].tools, isEmpty);
      }
    },
  );

  test('tool-only assistant turns survive every parser branch', () async {
    const tools = [
      {'name': 'read', 'arguments': ''},
    ];
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode([
          {'user': '', 'assistant': null, 'tools': tools},
          {'input': '', 'output': '', 'tools': tools},
          {'role': 'assistant', 'tools': tools},
          {'tools': tools},
          {'role': 'assistant', 'text': '', 'tools': []},
        ]),
        200,
      ),
    );
    addTearDown(client.close);
    final turns = await UhpService(client)
        .fetchSessionTurns(_server, 'session');
    expect(
      turns.map((turn) => (turn.role, turn.text, turn.tools.single.args)),
      [
        ('assistant', '', ''),
        ('assistant', '', ''),
        ('assistant', '', ''),
        ('assistant', '', ''),
      ],
    );
  });

  test('server search preview uses only first user_prompt line', () {
    expect(
      ServerSession.fromJson({
        'id': 's',
        'title': 'Title',
        'user_prompt': ' First line\r\nOther line',
      }).firstUserLine,
      'First line',
    );
    expect(
      ServerSession.fromJson({'id': 's', 'title': 'Title'}).firstUserLine,
      '',
    );
    expect(
      ServerSession.fromJson({'id': 's', 'user_prompt': 42}).firstUserLine,
      '',
    );
  });

  group('stored tools and preview migration', () {
    late Directory directory;
    late ThreadStore store;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('tool-data-');
      store = ThreadStore(() async => directory);
    });
    tearDown(() async => directory.delete(recursive: true));

    test(
      'tools round-trip verbatim and legacy messages remain readable',
      () async {
        await store.save(_thread());
        final reopened = ThreadStore(() async => directory);
        final thread = (await reopened.read('thread'))!;
        expect(thread.messages.last.tools.single.toJson(), _tool.toJson());
        final legacy = thread.messages.last.toJson()..remove('tools');
        expect(ThreadMessage.fromJson(legacy).tools, isEmpty);
        legacy['tools'] = [];
        expect(ThreadMessage.fromJson(legacy).tools, isEmpty);
        expect(
          (await reopened.loadIndex()).single.firstUserLine,
          'First question',
        );
        final appended = thread.appendTurn(
          'More',
          const ResponseRecord(
            prompt: 'More',
            output: 'Next',
            responseId: 'next',
            sessionId: 'session',
          ),
        );
        await reopened.save(appended);
        expect(
          (await reopened.read('thread'))!.messages[1].tools.single.args,
          _tool.args,
        );
      },
    );

    test(
      'refresh replaces fetched tools without losing local row metadata',
      () async {
        final original = _thread();
        await store.save(original);
        const refreshedTool = ToolCall(name: 'grep', args: '{"pattern":"new"}');
        final refreshed = await store.linkServerSession(
          server: _server,
          session: _session,
          harnessName: 'Harness',
          turns: [
            SessionTurn(
              role: 'user',
              text: buildAttachmentInput(
                original.messages.first.text,
                original.messages.first.attachments,
              ),
            ),
            const SessionTurn(
              role: 'assistant',
              text: 'Answer',
              tools: [refreshedTool],
            ),
          ],
        );
        expect(refreshed.id, original.id);
        expect(refreshed.title, original.title);
        expect(refreshed.archived, isTrue);
        expect(
          refreshed.messages.first.toJson(),
          original.messages.first.toJson(),
        );
        final expected = original.messages.last.toJson()
          ..['tools'] = [refreshedTool.toJson()];
        expect(refreshed.messages.last.toJson(), expected);
        expect(
          (await store.read(original.id))!.messages.last.toJson(),
          expected,
        );
      },
    );

    test(
      'tool-only transcript refresh is not mistaken for an empty fetch',
      () async {
        final first = await store.linkServerSession(
          server: _server,
          session: _session,
          harnessName: 'Harness',
          turns: const [
            SessionTurn(role: 'assistant', text: '', tools: [_tool]),
          ],
        );
        final refreshed = await store.linkServerSession(
          server: _server,
          session: _session,
          harnessName: 'Harness',
          turns: const [
            SessionTurn(
              role: 'assistant',
              text: '',
              tools: [ToolCall(name: 'glob', args: '{"path":"*"}')],
            ),
          ],
        );
        expect(refreshed.messages.single.tools.single.name, 'glob');
        expect(
          refreshed.messages.single.createdAt,
          first.messages.single.createdAt,
        );
        final emptyFetch = await store.linkServerSession(
          server: _server,
          session: _session,
          harnessName: 'Harness',
          turns: const [],
        );
        expect(emptyFetch.messages.single.tools.single.name, 'glob');
      },
    );

    test('continuation settlement retains transcript tools', () async {
      await store.save(_thread(status: TurnStatus.serverContinuing));
      await store.settleResponse('thread', 'response', {
        'id': 'response',
        'status': 'completed',
        'output': [
          {
            'role': 'assistant',
            'content': [
              {'text': 'Final'},
            ],
          },
        ],
      });
      final settled = (await store.read('thread'))!.messages.last;
      expect(settled.text, 'Final');
      expect(settled.tools.single.args, _tool.args);
      expect(settled.createdAt, _created);
    });

    test('index preview migration preserves malformed files and unrelated metadata once', () async {
      final good = _thread();
      final broken = _thread(id: 'broken');
      await store.save(good);
      await store.save(broken);
      final indexFile = File('${directory.path}/threads/index.json');
      final rows = (jsonDecode(await indexFile.readAsString()) as List)
          .cast<Map<String, dynamic>>();
      for (final row in rows) {
        row.remove('firstUserLine');
        row['futureMetadata'] = {
          'opaque': [1, true],
        };
      }
      await indexFile.writeAsString(jsonEncode(rows));
      final goodFile = File('${directory.path}/threads/thread.json');
      final before = await goodFile.readAsString();
      final brokenFile = File('${directory.path}/threads/broken.json');
      await brokenFile.writeAsString('{broken');
      final summaries = await ThreadStore(() async => directory).loadIndex();
      expect(
        summaries.map((summary) => (summary.id, summary.firstUserLine)).toSet(),
        {('thread', 'First question'), ('broken', '')},
      );
      final expectedRows = [
        for (final row in rows)
          {
            ...row,
            'firstUserLine': row['id'] == 'thread' ? 'First question' : '',
          },
      ];
      expect(jsonDecode(await indexFile.readAsString()), expectedRows);
      expect(await goodFile.readAsString(), before);
      expect(await brokenFile.readAsString(), '{broken');
      final migratedBytes = await indexFile.readAsString();
      await goodFile.writeAsString('{now broken too');
      final again = await ThreadStore(() async => directory).loadIndex();
      expect(
        again.firstWhere((summary) => summary.id == 'thread').firstUserLine,
        'First question',
      );
      expect(await indexFile.readAsString(), migratedBytes);
    });
  });
}
