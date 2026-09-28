import 'dart:async';
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
  apiKey: 'key',
  accessTokenId: 'edge-id',
  accessToken: 'edge-token',
);

class _StreamClient extends http.BaseClient {
  _StreamClient(this.handler);
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
  @override
  void close() {
    closed = true;
  }
}

void main() {
  test('lists actual gateway shapes and scopes changed files', () async {
    final requests = <http.Request>[];
    final service = UhpService(
      MockClient((request) async {
        requests.add(request);
        return http.Response(
          jsonEncode({
            'files': [
              {
                'id': 'old-id',
                'file_id': 'file/one',
                'container_id': 'session',
                'filename': 'report.csv',
                'path': 'output/report.csv',
                'bytes': 123,
                'media_type': 'text/csv',
                'download_url': 'https://other.test/file',
              },
              {'id': 'second', 'path': 'nested/photo.png', 'bytes': '2048'},
              {'path': 'missing-id'},
              null,
            ],
          }),
          200,
        );
      }),
    );
    final files = await service.fetchSessionFiles(
      _server,
      'session/a',
      changed: true,
    );
    expect(files.map((file) => file.id), ['file/one', 'second']);
    expect(files.first.filename, 'report.csv');
    expect(files.first.path, 'output/report.csv');
    expect(files.first.bytes, 123);
    expect(files.first.containerId, 'session');
    expect(files.first.mediaType, 'text/csv');
    expect(files.last.filename, 'photo.png');
    expect(files.last.bytes, 2048);
    expect(requests.single.url.queryParameters, {'changed': 'true'});
    expect(requests.single.url.pathSegments, contains('session/a'));
    await service.fetchSessionFiles(_server, 'session/a');
    expect(requests.last.url.queryParameters, isEmpty);
  });

  test('only explicit no-workspace 404 becomes an empty list', () async {
    var message = 'no workspace for this session yet — run a task first';
    final service = UhpService(
      MockClient(
        (_) async => http.Response(
          jsonEncode({'detail': message}),
          404,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
    );
    expect(await service.fetchSessionFiles(_server, 'session'), isEmpty);
    message = 'session not found';
    await expectLater(
      service.fetchSessionFiles(_server, 'session'),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 404)),
    );
  });

  late Directory cache;
  setUp(() async {
    cache = await Directory.systemTemp.createTemp('session-files-test-');
  });
  tearDown(() async {
    await cache.delete(recursive: true);
  });

  test(
    'downloads authenticated raw bytes only from encoded content route',
    () async {
      final client = _StreamClient((request) async {
        expect(request.url.host, 'example.test');
        expect(
          request.url.pathSegments,
          containsAllInOrder([
            'containers',
            'session/a',
            'files',
            'file/a',
            'content',
          ]),
        );
        expect(request.headers['Authorization'], 'Bearer key');
        expect(request.headers['P-Access-Token-Id'], 'edge-id');
        expect(request.headers['P-Access-Token'], 'edge-token');
        expect(request.followRedirects, isFalse);
        return http.StreamedResponse(
          Stream.fromIterable([
            [0, 255],
            [7, 8],
          ]),
          200,
          contentLength: 4,
        );
      });
      final progress = <int>[];
      final service = SessionFilesService(
        client,
        cacheDirectory: () async => cache,
      );
      const remote = SessionFile(
        id: 'file/a',
        filename: '../../report.bin',
        containerId: 'wrong-container',
        downloadUrl: 'https://other.test/stolen',
      );
      final result = await service
          .download(
            _server,
            'session/a',
            remote,
            onProgress: (received, _) => progress.add(received),
          )
          .result;
      expect(await result.readAsBytes(), [0, 255, 7, 8]);
      expect(result.path, startsWith('${cache.path}/session-files/'));
      expect(result.uri.pathSegments.last, 'report.bin');
      expect(progress, [0, 2, 4]);
      expect(client.closed, isFalse);
    },
  );

  test('archive uses authenticated session route and changed filter', () async {
    final service = SessionFilesService(
      _StreamClient((request) async {
        expect(
          request.url.path,
          '/api/harness/v1/sessions/session/files/archive',
        );
        expect(request.url.queryParameters, {'changed': 'true'});
        expect(request.headers['Authorization'], 'Bearer key');
        return http.StreamedResponse(Stream.value([80, 75, 3, 4]), 200);
      }),
      cacheDirectory: () async => cache,
    );
    final file = await service
        .archive(_server, 'session', changed: true, onProgress: (_, _) {})
        .result;
    expect(file.path, endsWith('.zip'));
    expect(await file.readAsBytes(), [80, 75, 3, 4]);
  });

  test(
    'HTTP failures and truncated bodies remove partial download directories',
    () async {
      var status = 404;
      final service = SessionFilesService(
        _StreamClient(
          (_) async => http.StreamedResponse(
            Stream.value(utf8.encode('missing file')),
            status,
            contentLength: 100,
          ),
        ),
        cacheDirectory: () async => cache,
      );
      const file = SessionFile(id: 'id', filename: 'file');
      await expectLater(
        service.download(_server, 'sid', file, onProgress: (_, _) {}).result,
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 404)),
      );
      expect(
        await Directory('${cache.path}/session-files').list().toList(),
        isEmpty,
      );
      status = 200;
      await expectLater(
        service.download(_server, 'sid', file, onProgress: (_, _) {}).result,
        throwsA(isA<AppError>()),
      );
      expect(
        await Directory('${cache.path}/session-files').list().toList(),
        isEmpty,
      );
    },
  );

  test(
    'cancel releases stalled stream and removes bytes before completing',
    () async {
      final body = StreamController<List<int>>();
      var cancelled = false;
      body.onCancel = () {
        cancelled = true;
      };
      final service = SessionFilesService(
        _StreamClient((_) async => http.StreamedResponse(body.stream, 200)),
        cacheDirectory: () async => cache,
      );
      final written = Completer<void>();
      final operation = service.download(
        _server,
        'sid',
        const SessionFile(id: 'id', filename: 'file'),
        onProgress: (received, _) {
          if (received > 0) written.complete();
        },
      );
      final failure = expectLater(
        operation.result,
        throwsA(isA<SessionFileCancelled>()),
      );
      body.add([1, 2, 3]);
      await written.future;
      operation.cancel();
      await failure;
      expect(cancelled, isTrue);
      expect(
        await Directory('${cache.path}/session-files').list().toList(),
        isEmpty,
      );
      await body.close();
    },
  );

  test('redirects are not followed and leave no partial file', () async {
    final client = _StreamClient((request) async {
      expect(request.followRedirects, isFalse);
      return http.StreamedResponse(
        Stream.value([]),
        302,
        headers: {'location': 'https://other.test/file'},
      );
    });
    final service = SessionFilesService(
      client,
      cacheDirectory: () async => cache,
    );
    await expectLater(
      service
          .download(
            _server,
            'sid',
            const SessionFile(id: 'id', filename: 'file'),
            onProgress: (_, _) {},
          )
          .result,
      throwsA(isA<AuthException>()),
    );
    expect(
      await Directory('${cache.path}/session-files').list().toList(),
      isEmpty,
    );
    expect(client.closed, isFalse);
  });
}
