import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:uhp_android/main.dart';

const _server = ServerConfig(
  id: 'server',
  name: 'Server',
  baseUrl: 'https://example.test',
  apiKey: 'key',
);

class _FilePlatform extends SessionFilePlatform {
  final opened = Completer<String>();
  final shared = <String>[];
  @override
  Future<bool> openFile(String path, String? mediaType) async {
    opened.complete(path);
    return false;
  }

  @override
  Future<void> shareFile(String path, String? mediaType) async {
    shared.add(path);
  }
}

void main() {
  testWidgets(
    'rows show gateway filename path size and changed filter refreshes',
    (tester) async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        return http.Response(
          jsonEncode({
            'files': request.url.queryParameters['changed'] == 'true'
                ? []
                : [
                    {
                      'file_id': 'one',
                      'filename': 'report.csv',
                      'path': 'results/report.csv',
                      'bytes': 4096,
                      'media_type': 'text/csv',
                    },
                  ],
          }),
          200,
        );
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [httpClientProvider.overrideWithValue(client)],
          child: const MaterialApp(
            home: Scaffold(
              body: SessionFilesSheet(server: _server, sessionId: 'sid'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('report.csv'), findsOneWidget);
      expect(find.text('results/report.csv\n4.0 KB'), findsOneWidget);
      expect(find.text('Download all (.zip)'), findsOneWidget);
      await tester.tap(find.text('New this turn'));
      await tester.pumpAndSettle();
      expect(requests.last.url.queryParameters, {'changed': 'true'});
      expect(find.text('report.csv'), findsNothing);
      expect(find.text('No new files this turn.'), findsOneWidget);
      await tester.drag(find.byType(ListView), const Offset(0, 300));
      await tester.pumpAndSettle();
      expect(requests.length, 3);
    },
  );

  testWidgets('a real list failure is visible and retry recovers', (
    tester,
  ) async {
    var fail = true;
    final client = MockClient(
      (_) async => fail
          ? http.Response('{"detail":"session not found"}', 404)
          : http.Response('{"files":[]}', 200),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [httpClientProvider.overrideWithValue(client)],
        child: const MaterialApp(
          home: Scaffold(
            body: SessionFilesSheet(server: _server, sessionId: 'sid'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('HTTP 404'), findsOneWidget);
    expect(
      find.text('No workspace files yet. Run a task to create files.'),
      findsNothing,
    );
    fail = false;
    await tester.tap(find.text('Retry files'));
    await tester.pumpAndSettle();
    expect(find.textContaining('HTTP 404'), findsNothing);
    expect(
      find.text('No workspace files yet. Run a task to create files.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'completed download opens and offers share when no viewer exists',
    (tester) async {
      final cache = await tester.runAsync(
        () => Directory.systemTemp.createTemp('files-ui-'),
      );
      final platform = (await tester.runAsync(() async => _FilePlatform()))!;
      final client = MockClient(
        (request) async => request.url.path.endsWith('/content')
            ? http.Response.bytes([1, 2, 3], 200)
            : http.Response(
                jsonEncode({
                  'files': [
                    {'id': 'one', 'filename': 'data.bin', 'bytes': 3},
                  ],
                }),
                200,
              ),
      );
      addTearDown(() async {
        client.close();
        await tester.runAsync(() => cache!.delete(recursive: true));
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            httpClientProvider.overrideWithValue(client),
            sessionFilePlatformProvider.overrideWithValue(platform),
            sessionFilesServiceProvider.overrideWithValue(
              SessionFilesService(client, cacheDirectory: () async => cache!),
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: SessionFilesSheet(server: _server, sessionId: 'sid'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        tester.widget<ListTile>(find.byType(ListTile)).onTap!();
        await platform.opened.future;
      });
      await tester.pumpAndSettle();
      expect(find.textContaining('No app can open this file'), findsOneWidget);
      expect(find.text('Share file'), findsOneWidget);
      await tester.tap(find.text('Share file'));
      await tester.pumpAndSettle();
      expect(platform.shared, [
        await tester.runAsync(() => platform.opened.future),
      ]);
      expect(
        await tester.runAsync(() => File(platform.shared.single).readAsBytes()),
        [1, 2, 3],
      );
    },
  );
}
