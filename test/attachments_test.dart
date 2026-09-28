import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uhp_android/main.dart';

const _server = ServerConfig(
  id: 'profile',
  name: 'Server',
  baseUrl: 'https://example.test',
  apiKey: ' key ',
  accessTokenId: ' edge-id ',
  accessToken: ' edge-token ',
);
const _harness = Harness(
  id: 'h',
  name: 'Harness',
  baseLabel: '',
  defaultModel: '',
);
const _attachment = MessageAttachment(
  id: 'file_abc',
  name: 'notes.txt',
  bytes: 4,
  mediaType: 'text/plain',
);

class _Client extends http.BaseClient {
  _Client(this.handle);
  final Future<http.StreamedResponse> Function(http.BaseRequest) handle;
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handle(request);
  @override
  void close() => closed = true;
}

http.StreamedResponse _json(Object data) => http.StreamedResponse(
  Stream.value(utf8.encode(jsonEncode(data))),
  200,
  headers: {'content-type': 'application/json'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late PickedAttachment pick;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('attachments-');
    final file = await File('${directory.path}/notes.txt')
        .writeAsString('note');
    pick = PickedAttachment(
      path: file.path,
      name: 'notes.txt',
      size: 4,
      mediaType: 'text/plain',
    );
  });
  tearDown(() async => directory.delete(recursive: true));

  Future<ProviderContainer> containerFor(http.Client client) async {
    SharedPreferences.setMockInitialValues({
      ServerStore.key: jsonEncode([_server.toJson()]),
    });
    final container = ProviderContainer(
      overrides: [
        httpClientProvider.overrideWithValue(client),
        threadStoreProvider.overrideWithValue(
          ThreadStore(() async => Directory('${directory.path}/threads')),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(serversProvider.future);
    container.read(selectedServerProvider.notifier).state = _server;
    container.read(selectedHarnessProvider.notifier).state = _harness;
    return container;
  }

  test('notes preserve original prompt and attachment-only input', () {
    expect(
      buildAttachmentInput('  question  ', [_attachment]),
      '  question  \n<attachment id=file_abc filename=notes.txt>',
    );
    expect(
      buildAttachmentInput('', [_attachment]),
      '<attachment id=file_abc filename=notes.txt>',
    );
    expect(buildAttachmentInput('question', []), 'question');
    expect(
      buildAttachmentInput('question', [
        _attachment,
        const MessageAttachment(
          id: 'file_def',
          name: 'second file.pdf',
          bytes: 9,
        ),
      ]),
      'question\n<attachment id=file_abc filename=notes.txt>\n<attachment id=file_def filename=second file.pdf>',
    );
  });

  test(
    'old rows deserialize and new metadata survives a durable round trip',
    () async {
      final old = ThreadMessage.fromJson({
        'role': 'user',
        'text': 'old',
        'createdAt': '2026-01-01T00:00:00Z',
      });
      expect(old.attachments, isEmpty);
      final attachments = [_attachment];
      final thread = ConversationThread.start(
        server: _server,
        harness: _harness,
        prompt: 'question',
        record: const ResponseRecord(
          prompt: 'question',
          output: 'answer',
          responseId: 'r',
          sessionId: 's',
        ),
        attachments: attachments,
      );
      attachments.clear();
      final store = ThreadStore(
        () async => Directory('${directory.path}/threads'),
      );
      await store.save(
        thread.appendTurn(
          'next',
          const ResponseRecord(
            prompt: 'next',
            output: 'answer 2',
            responseId: 'r2',
            sessionId: 's',
          ),
          attachments: [_attachment],
        ),
      );
      final loaded = (await store.read(thread.id))!;
      expect(
        loaded.messages.first.attachments.single.toJson(),
        _attachment.toJson(),
      );
      expect(
        loaded.messages[2].attachments.single.toJson(),
        _attachment.toJson(),
      );
      expect(
        () => loaded.messages.first.attachments.clear(),
        throwsUnsupportedError,
      );
    },
  );

  test(
    'all caps and actual file sizes are checked before any upload',
    () async {
      var requests = 0;
      final client = _Client((_) async {
        requests++;
        return _json({});
      });
      final large = File('${directory.path}/large');
      final handle = await large.open(mode: FileMode.write);
      await handle.truncate(maxAttachmentBytes + 1);
      await handle.close();
      for (final invalid in [
        PickedAttachment(
          path: pick.path,
          name: 'declared-large',
          size: maxAttachmentBytes + 1,
        ),
        PickedAttachment(path: large.path, name: 'actual-large', size: 1),
        PickedAttachment(path: pick.path, name: 'changed', size: 3),
      ]) {
        await expectLater(
          AttachmentUpload(client, _server, [pick, invalid]).run(),
          throwsA(isA<AppError>()),
        );
      }
      expect(requests, 0);
    },
  );

  test(
    'multipart carries file, purpose and profile auth without a JSON boundary',
    () async {
      final client = _Client((request) async {
        expect(request.url.path, '/api/harness/v1/files');
        final body = await request.finalize().bytesToString();
        expect(
          request.headers['content-type'],
          startsWith('multipart/form-data; boundary='),
        );
        expect(request.headers['authorization'], 'Bearer key');
        expect(request.headers['P-Access-Token-Id'], 'edge-id');
        expect(request.headers['P-Access-Token'], 'edge-token');
        expect(request.followRedirects, isFalse);
        expect(body, contains('name="purpose"\r\n\r\nuser_data'));
        expect(body, contains('name="file"; filename="notes.txt"\r\n\r\nnote'));
        return _json({'id': 'file_abc', 'bytes': 4});
      });
      final result = await AttachmentUpload(client, _server, [pick]).run();
      expect(result.single.toJson(), _attachment.toJson());
      expect(client.closed, isFalse);
    },
  );

  test('exactly 25 MiB streams successfully at the inclusive limit', () async {
    final file = File('${directory.path}/boundary');
    final handle = await file.open(mode: FileMode.write);
    await handle.truncate(maxAttachmentBytes);
    await handle.close();
    final boundaryPick = PickedAttachment(
      path: file.path,
      name: 'boundary',
      size: maxAttachmentBytes,
    );
    final client = _Client((request) async {
      final count = await request.finalize().fold<int>(
        0,
        (count, chunk) => count + chunk.length,
      );
      expect(count, request.contentLength);
      return _json({'id': 'file_boundary', 'bytes': maxAttachmentBytes});
    });
    final result = await AttachmentUpload(client, _server, [
      boundaryPick,
    ]).run();
    expect(result.single.bytes, maxAttachmentBytes);
  });

  test(
    'changed file is rejected by streaming guard after stat preflight',
    () async {
      final client = _Client((request) async {
        await File(pick.path).writeAsString('longer than selected');
        await request.finalize().drain<void>();
        return _json({'id': 'file_abc', 'bytes': 4});
      });
      await expectLater(
        AttachmentUpload(client, _server, [pick]).run(),
        throwsA(isA<AppError>()),
      );
    },
  );

  test('invalid returned file identities and sizes are rejected', () async {
    for (final payload in [
      {'id': '', 'bytes': 4},
      {'id': 'file_bad\nline', 'bytes': 4},
      {'id': 'file_abc', 'bytes': 3},
      {'bytes': 4},
    ]) {
      final client = _Client((request) async {
        await request.finalize().drain<void>();
        return _json(payload);
      });
      await expectLater(
        AttachmentUpload(client, _server, [pick]).run(),
        throwsA(isA<AppError>()),
      );
    }
  });

  test(
    'turn receives notes but local user text and metadata stay separate',
    () async {
      final paths = <String>[];
      final client = _Client((request) async {
        paths.add(request.url.path);
        if (request.url.path == '/api/harness/v1/files') {
          await request.finalize().drain<void>();
          return _json({'id': 'file_abc', 'bytes': 4});
        }
        final body =
            jsonDecode(await request.finalize().bytesToString()) as Map;
        expect(
          body['input'],
          'question\n<attachment id=file_abc filename=notes.txt>',
        );
        return _json({'id': 'r', 'status': 'completed', 'output': 'answer'});
      });
      final container = await containerFor(client);
      final runner = container.read(taskRunnerProvider);
      await runner.submit('question', attachments: [pick]);
      expect(paths, ['/api/harness/v1/files', '/api/harness/v1/responses']);
      final thread = container.read(threadProvider)!;
      expect(thread.messages.first.text, 'question');
      expect(
        thread.messages.first.attachments.single.toJson(),
        _attachment.toJson(),
      );
      expect(runner.submissionRecorded, isTrue);
      await expectLater(runner.submit(''), throwsA(isA<AppError>()));
      expect(runner.submissionRecorded, isFalse);
    },
  );

  test(
    'attachment-only turn records an empty prompt and filename title',
    () async {
      final client = _Client((request) async {
        final body = await request.finalize().bytesToString();
        if (request.url.path == '/api/harness/v1/files') {
          return _json({'id': 'file_abc', 'bytes': 4});
        }
        expect(
          jsonDecode(body)['input'],
          '<attachment id=file_abc filename=notes.txt>',
        );
        return _json({'id': 'r', 'output': 'answer'});
      });
      final container = await containerFor(client);
      await container.read(taskRunnerProvider).submit('', attachments: [pick]);
      expect(container.read(threadProvider)!.messages.first.text, '');
      expect(container.read(threadProvider)!.title, 'notes.txt');
    },
  );

  test('upload rejection leaves no phantom turn and allows retry', () async {
    var reject = true;
    final client = _Client((request) async {
      await request.finalize().drain<void>();
      if (request.url.path == '/api/harness/v1/files') {
        if (reject) {
          return http.StreamedResponse(
            Stream.value(utf8.encode('rejected')),
            413,
          );
        }
        return _json({'id': 'file_abc', 'bytes': 4});
      }
      return _json({'id': 'r', 'output': 'answer'});
    });
    final container = await containerFor(client);
    final runner = container.read(taskRunnerProvider);
    await expectLater(
      runner.submit('question', attachments: [pick]),
      throwsA(isA<ApiException>()),
    );
    expect(container.read(threadProvider), isNull);
    expect(container.read(unsavedThreadProvider), isNull);
    expect(runner.submissionRecorded, isFalse);
    reject = false;
    await runner.submit('question', attachments: [pick]);
    expect(runner.submissionRecorded, isTrue);
  });

  test('recorded turn retains attachments when persistence fails', () async {
    final client = _Client((request) async {
      await request.finalize().drain<void>();
      return request.url.path == '/api/harness/v1/files'
          ? _json({'id': 'file_abc', 'bytes': 4})
          : _json({'id': 'r', 'output': 'answer'});
    });
    final container = await containerFor(client);
    // Block the store directory, not the upload source.
    await File('${directory.path}/threads').writeAsString('blocked');
    final runner = container.read(taskRunnerProvider);
    await expectLater(
      runner.submit('question', attachments: [pick]),
      throwsA(isA<FileSystemException>()),
    );
    expect(runner.submissionRecorded, isTrue);
    expect(
      container
          .read(unsavedThreadProvider)!
          .messages
          .first
          .attachments
          .single
          .id,
      'file_abc',
    );
    expect(container.read(threadProvider)!.messages.first.text, 'question');
  });

  for (final action in ['stop', 'background', 'dispose']) {
    test('$action aborts pending upload and never starts a response', () async {
      final started = Completer<void>();
      final aborted = Completer<void>();
      final paths = <String>[];
      final client = _Client((request) async {
        paths.add(request.url.path);
        started.complete();
        await (request as http.Abortable).abortTrigger;
        aborted.complete();
        throw http.RequestAbortedException();
      });
      final container = await containerFor(client);
      final runner = container.read(taskRunnerProvider);
      final submission = runner.submit('question', attachments: [pick]);
      final failure = expectLater(submission, throwsA(isA<AppError>()));
      await started.future;
      if (action == 'dispose') {
        runner.dispose();
      } else {
        try {
          await (action == 'stop' ? runner.cancel() : runner.background());
        } on AppError {
          // The stopped submission remains an error so the composer keeps its draft.
        }
      }
      await failure;
      await aborted.future;
      expect(paths, ['/api/harness/v1/files']);
      expect(container.read(threadProvider), isNull);
      expect(runner.submissionRecorded, isFalse);
      expect(client.closed, isFalse);
    });
  }

  test('server refresh retains original text and uploaded metadata without duplicate pairs', () async {
    final store = ThreadStore(
      () async => Directory('${directory.path}/threads'),
    );
    const session = ServerSession(
      id: 'session',
      title: 'Session',
      harnessId: 'h',
      lastResponseId: 'r',
    );
    final linked = await store.linkServerSession(
      server: _server,
      session: session,
      turns: [],
      harnessName: 'Harness',
    );
    await store.save(
      linked.appendTurn(
        'question',
        const ResponseRecord(
          prompt: 'question',
          output: 'answer',
          responseId: 'r',
          sessionId: 'session',
        ),
        attachments: [_attachment],
      ),
    );
    final refreshed = await store.linkServerSession(
      server: _server,
      session: session,
      harnessName: 'Harness',
      turns: [
        SessionTurn(
          role: 'user',
          text: buildAttachmentInput('question', [_attachment]),
        ),
        const SessionTurn(role: 'assistant', text: 'answer'),
      ],
    );
    expect(refreshed.messages.map((row) => row.text), ['question', 'answer']);
    expect(
      refreshed.messages.first.attachments.single.toJson(),
      _attachment.toJson(),
    );
    expect(refreshed.messages.last.responseId, 'r');
  });
}
