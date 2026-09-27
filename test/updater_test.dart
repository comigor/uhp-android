import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:uhp_android/updater.dart';

class _Client extends http.BaseClient {
  _Client(this.handle);

  final Future<http.StreamedResponse> Function(http.BaseRequest) handle;
  final requests = <http.BaseRequest>[];
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests.add(request);
    return handle(request);
  }

  @override
  void close() => closed = true;
}

Map<String, dynamic> _asset(String name, {int size = 5}) => {
  'name': name,
  'browser_download_url':
      'https://github.com/comigor/uhp-android/releases/$name',
  'size': size,
};

Map<String, dynamic> _releaseJson() => {
  'tag_name': 'v1.2.3',
  'name': 'A release',
  'body': 'Release notes',
  'assets': [_asset('app.apk')],
};

ReleaseInfo _release({int size = 5, String tag = 'v1.2.3'}) => ReleaseInfo(
  tag: tag,
  name: 'A release',
  notes: 'Release notes',
  apk: ApkAsset(
    name: 'app.apk',
    url: Uri.parse('https://github.com/comigor/uhp-android/releases/app.apk'),
    size: size,
  ),
);

http.StreamedResponse _json(Object? body, {int status = 200}) =>
    http.StreamedResponse(Stream.value(utf8.encode(jsonEncode(body))), status);

void _expectPublic(http.BaseRequest request) {
  final headers = request.headers.map(
    (key, value) => MapEntry(key.toLowerCase(), value),
  );
  for (final name in [
    'authorization',
    'proxy-authorization',
    'cookie',
    'x-api-key',
    'p-access-token-id',
    'p-access-token',
  ]) {
    expect(
      headers,
      isNot(contains(name)),
      reason: '$name must not reach GitHub',
    );
  }
  expect(request.url.userInfo, isEmpty);
}

void main() {
  group('versions', () {
    test('compares numeric components, not lexical strings', () {
      expect(compareVersions('v0.3.1', 'v0.4.0'), lessThan(0));
      expect(compareVersions('v0.4.0', 'v0.4.0'), 0);
      expect(compareVersions('v0.0.0-dev', 'v0.4.0'), lessThan(0));
      expect(compareVersions('v0.3.1', 'v0.3.2'), lessThan(0));
      expect(compareVersions('v1.10.0', '1.9.99'), greaterThan(0));
      expect(compareVersions('v2.0.0', 'v10.0.0'), lessThan(0));
      expect(compareVersions('1.2.4', 'v1.2.3'), greaterThan(0));
    });

    test('missing and nonnumeric components are zero; extras are ignored', () {
      expect(compareVersions('v1.2', '1.2.0'), 0);
      expect(compareVersions('v1.x.3', '1.0.3'), 0);
      expect(compareVersions('v1.2.3-dev', '1.2.0'), 0);
      expect(compareVersions('1.2.3.999', 'v1.2.3'), 0);
      expect(compareVersions('', 'v0.0.0-dev'), 0);
    });
  });

  group('release parsing', () {
    test(
      'preserves metadata and selects the first usable APK among assets',
      () {
        final json = _releaseJson();
        json['assets'] = [
          null,
          _asset('source.zip'),
          {..._asset('invalid.apk'), 'browser_download_url': '/relative.apk'},
          {
            ..._asset('credential.apk'),
            'browser_download_url': 'https://secret@github.com/app.apk',
          },
          {..._asset('bad-size.apk'), 'size': '5'},
          _asset('first.apk', size: 123),
          _asset('second.apk'),
        ];
        final release = parseRelease(json);
        expect(release.tag, 'v1.2.3');
        expect(release.name, 'A release');
        expect(release.notes, 'Release notes');
        expect(release.apk.name, 'first.apk');
        expect(release.apk.size, 123);
        expect(release.apk.url.toString(), endsWith('/first.apk'));
      },
    );

    test('nullable GitHub text remains usable', () {
      final release = parseRelease({
        ..._releaseJson(),
        'name': null,
        'body': null,
      });
      expect(release.name, release.tag);
      expect(release.notes, isEmpty);
    });

    test('reports no APK for empty or non-APK assets', () {
      for (final assets in <List<dynamic>>[
        [],
        [_asset('source.zip')],
      ]) {
        expect(
          () => pickApkAsset(assets),
          throwsA(
            isA<UpdateException>().having(
              (error) => error.message,
              'message',
              contains('APK'),
            ),
          ),
        );
      }
    });

    test('rejects malformed release structure', () {
      for (final json in [
        {..._releaseJson(), 'tag_name': ''},
        {..._releaseJson(), 'assets': {}},
        {..._releaseJson(), 'body': 42},
      ]) {
        expect(() => parseRelease(json), throwsA(isA<UpdateException>()));
      }
    });
  });

  group('release checks', () {
    test(
      'requests the public latest endpoint without profile credentials',
      () async {
        final client = _Client((request) async => _json(_releaseJson()));
        final release = await UpdateService(client).check();
        expect(release.tag, 'v1.2.3');
        final request = client.requests.single;
        expect(request.method, 'GET');
        expect(
          request.url.toString(),
          'https://api.github.com/repos/comigor/uhp-android/releases/latest',
        );
        expect(request.headers['Accept'], 'application/vnd.github+json');
        expect(request.headers['User-Agent'], contains('uhp-android'));
        _expectPublic(request);
        expect(client.closed, isFalse);
      },
    );

    test('403 explains the rate limit and a recovery action', () async {
      final client = _Client((request) async => _json({}, status: 403));
      await expectLater(
        UpdateService(client).check(),
        throwsA(
          isA<UpdateException>()
              .having((error) => error.message, 'status', contains('403'))
              .having(
                (error) => error.message,
                'guidance',
                contains('rate-limit'),
              )
              .having((error) => error.message, 'retry', contains('try again')),
        ),
      );
      expect(client.closed, isFalse);
    });

    test('HTTP, malformed JSON and network errors are readable', () async {
      final cases =
          <(Future<http.StreamedResponse> Function(http.BaseRequest), String)>[
            ((request) async => _json({}, status: 502), '502'),
            (
              (request) async => http.StreamedResponse(
                Stream.value(utf8.encode('{broken')),
                200,
              ),
              'malformed',
            ),
            ((request) async => _json([]), 'malformed'),
            (
              (request) async => throw const SocketException('offline'),
              'offline',
            ),
          ];
      for (final (handler, message) in cases) {
        final client = _Client(handler);
        await expectLater(
          UpdateService(client).check(),
          throwsA(
            isA<UpdateException>().having(
              (error) => error.message,
              'message',
              contains(message),
            ),
          ),
        );
        expect(client.closed, isFalse);
      }
    });
  });

  group('streamed APK downloads', () {
    late Directory cache;

    setUp(() async {
      cache = await Directory.systemTemp.createTemp('uhp-updater-test-');
    });

    tearDown(() async {
      await cache.delete(recursive: true);
    });

    UpdateService service(_Client client) =>
        UpdateService(client, cacheDirectory: () async => cache);

    Future<void> expectNoApk() async {
      final files = await cache
          .list(recursive: true)
          .where((entry) => entry is File)
          .toList();
      expect(files, isEmpty);
    }

    test('writes real streamed chunks and reports content length before asset size', () async {
      final body = StreamController<List<int>>();
      final firstWritten = Completer<void>();
      final client = _Client(
        (request) async =>
            http.StreamedResponse(body.stream, 200, contentLength: 5),
      );
      final progress = <(int, int?)>[];
      final download = service(client).startDownload(
        _release(size: 999),
        onProgress: (received, total) {
          progress.add((received, total));
          if (received == 2) firstWritten.complete();
        },
      );
      body.add([1, 2]);
      await firstWritten.future;
      final partial = File('${cache.path}/updates/uhp-update-v1.2.3.apk');
      expect(await partial.readAsBytes(), [1, 2]);
      body.add([3, 4, 5]);
      await body.close();
      final file = await download.result;
      expect(await file.readAsBytes(), [1, 2, 3, 4, 5]);
      expect(progress, [(0, 5), (2, 5), (5, 5)]);
      _expectPublic(client.requests.single);
      expect(client.closed, isFalse);
      download.cancel();
      expect(
        await file.exists(),
        isTrue,
        reason: 'Completed installers must remain available for handoff',
      );
    });

    test('falls back to asset size and sanitizes the release tag into the cache directory', () async {
      final client = _Client(
        (request) async => http.StreamedResponse(Stream.value([1, 2, 3]), 200),
      );
      final progress = <(int, int?)>[];
      final download = service(client).startDownload(
        _release(size: 3, tag: '../../bad/tag'),
        onProgress: (received, total) => progress.add((received, total)),
      );
      final file = await download.result;
      expect(file.parent.path, '${cache.path}/updates');
      expect(await file.readAsBytes(), [1, 2, 3]);
      expect(progress, [(0, 3), (3, 3)]);
    });

    test(
      'reports indeterminate progress when neither size is available',
      () async {
        final client = _Client(
          (request) async => http.StreamedResponse(Stream.value([1]), 200),
        );
        final progress = <(int, int?)>[];
        final file = await service(client)
            .startDownload(
              _release(size: 0),
              onProgress: (received, total) => progress.add((received, total)),
            )
            .result;
        expect(await file.readAsBytes(), [1]);
        expect(progress, [(0, null), (1, null)]);
      },
    );

    test('cancellation while waiting for cache prevents any request', () async {
      final cacheReady = Completer<Directory>();
      final client = _Client(
        (request) async => throw StateError('must not send'),
      );
      final download = UpdateService(
        client,
        cacheDirectory: () => cacheReady.future,
      ).startDownload(_release(), onProgress: (_, _) {});
      final result = expectLater(
        download.result,
        throwsA(isA<UpdateCancelled>()),
      );
      download.cancel();
      download.cancel();
      cacheReady.complete(cache);
      await result;
      expect(client.requests, isEmpty);
      await expectNoApk();
    });

    test('cancels before headers and disposes any late response without closing client', () async {
      final started = Completer<http.AbortableRequest>();
      final headers = Completer<http.StreamedResponse>();
      final disposed = Completer<void>();
      final body = StreamController<List<int>>(
        onCancel: () => disposed.complete(),
      );
      final client = _Client((request) {
        started.complete(request as http.AbortableRequest);
        return headers.future;
      });
      final download = service(client)
          .startDownload(_release(), onProgress: (_, _) {});
      final result = expectLater(
        download.result,
        throwsA(isA<UpdateCancelled>()),
      );
      final request = await started.future;
      download.cancel();
      await request.abortTrigger;
      await result;
      await expectNoApk();
      headers.complete(http.StreamedResponse(body.stream, 200));
      await disposed.future;
      await body.close();
      expect(client.closed, isFalse);
    });

    test('cancels a stalled chunk stream and removes its partial file before settling', () async {
      final body = StreamController<List<int>>();
      final firstWritten = Completer<void>();
      final client = _Client(
        (request) async =>
            http.StreamedResponse(body.stream, 200, contentLength: 5),
      );
      final download = service(client).startDownload(
        _release(),
        onProgress: (received, total) {
          if (received == 2) firstWritten.complete();
        },
      );
      final result = expectLater(
        download.result,
        throwsA(isA<UpdateCancelled>()),
      );
      body.add([1, 2]);
      await firstWritten.future;
      expect(
        await File('${cache.path}/updates/uhp-update-v1.2.3.apk').readAsBytes(),
        [1, 2],
      );
      download.cancel();
      await result;
      await expectNoApk();
      await body.close();
      expect(client.closed, isFalse);
    });

    test(
      'cancellation at full byte count still removes the not-yet-closed APK',
      () async {
        final body = StreamController<List<int>>();
        final client = _Client(
          (request) async =>
              http.StreamedResponse(body.stream, 200, contentLength: 3),
        );
        late UpdateDownload download;
        download = service(client).startDownload(
          _release(size: 3),
          onProgress: (received, total) {
            if (received == 3) download.cancel();
          },
        );
        final result = expectLater(
          download.result,
          throwsA(isA<UpdateCancelled>()),
        );
        body.add([1, 2, 3]);
        await result;
        await expectNoApk();
        await body.close();
      },
    );

    test(
      'short, oversized, and empty bodies never leave installable files',
      () async {
        for (final bytes in <List<int>>[
          [1, 2],
          [1, 2, 3, 4],
          [],
        ]) {
          final client = _Client(
            (request) async => http.StreamedResponse(
              Stream.value(bytes),
              200,
              contentLength: 3,
            ),
          );
          await expectLater(
            service(client)
                .startDownload(_release(size: 3), onProgress: (_, _) {})
                .result,
            throwsA(isA<UpdateException>()),
          );
          await expectNoApk();
          expect(client.closed, isFalse);
        }
      },
    );

    test('body network failure removes bytes already written', () async {
      final body = StreamController<List<int>>();
      final firstWritten = Completer<void>();
      final client = _Client(
        (request) async => http.StreamedResponse(body.stream, 200),
      );
      final download = service(client).startDownload(
        _release(),
        onProgress: (received, total) {
          if (received == 2) firstWritten.complete();
        },
      );
      final result = expectLater(
        download.result,
        throwsA(
          isA<UpdateException>().having(
            (error) => error.message,
            'message',
            contains('connection lost'),
          ),
        ),
      );
      body.add([1, 2]);
      await firstWritten.future;
      body.addError(const SocketException('connection lost'));
      await result;
      await expectNoApk();
      await body.close();
      expect(client.closed, isFalse);
    });

    test(
      'HTTP download failures do not create files or consume response bodies',
      () async {
        final disposed = Completer<void>();
        final body = StreamController<List<int>>(
          onCancel: () => disposed.complete(),
        );
        final client = _Client(
          (request) async => http.StreamedResponse(body.stream, 403),
        );
        await expectLater(
          service(client)
              .startDownload(_release(), onProgress: (_, _) {})
              .result,
          throwsA(
            isA<UpdateException>().having(
              (error) => error.message,
              'message',
              contains('rate-limit'),
            ),
          ),
        );
        await disposed.future;
        await expectNoApk();
        await body.close();
        expect(client.closed, isFalse);
      },
    );
  });
}
