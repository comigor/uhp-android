import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:uhp_android/main.dart';

const _server = ServerConfig(
  id: 'server',
  name: 'Server',
  baseUrl: 'https://example.test',
  apiKey: 'private-key',
  accessTokenId: 'edge-id',
  accessToken: 'edge-secret',
);

ConversationThread _thread({
  String? sid = 'session/one',
  String id = 'local',
}) => ConversationThread(
  id: id,
  title: 'Session',
  server: _server,
  harnessId: 'harness',
  harnessName: 'Harness',
  serverSessionId: sid,
  serverSessionStatus: 'running',
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
  messages: [
    ThreadMessage(
      role: 'assistant',
      text: 'Partial output',
      responseId: 'response',
      status: TurnStatus.serverContinuing,
      createdAt: DateTime.utc(2026),
    ),
  ],
);

void main() {
  test(
    'share restores, publishes canonical URL, and revokes with POST',
    () async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        final enabled = request.method == 'GET'
            ? false
            : (jsonDecode(request.body) as Map)['enabled'] as bool;
        return http.Response(
          jsonEncode({
            'enabled': enabled,
            'token': enabled ? 'shr0123456789' : '',
            'url': 'https://untrusted.test/?token=not-the-viewer',
          }),
          200,
        );
      });
      addTearDown(client.close);
      final service = UhpService(client);
      expect(
        (await service.fetchSessionShare(_server, 'session/one')).enabled,
        isFalse,
      );
      final published = await service.setSessionShare(
        _server,
        'session/one',
        enabled: true,
      );
      expect(
        published.publicUri(_server).toString(),
        'https://example.test/share/shr0123456789',
      );
      expect(
        (await service.setSessionShare(
          _server,
          'session/one',
          enabled: false,
        )).enabled,
        isFalse,
      );
      expect(requests.map((r) => r.method), ['GET', 'POST', 'POST']);
      expect(requests.last.body, '{"enabled":false}');
      for (final request in requests) {
        expect(
          request.url.toString(),
          'https://example.test/api/harness/v1/sessions/session%2Fone/share',
        );
        expect(request.headers['authorization'], 'Bearer private-key');
        expect(request.headers['p-access-token-id'], 'edge-id');
        expect(request.headers['p-access-token'], 'edge-secret');
        expect(request.followRedirects, isFalse);
      }
    },
  );

  test('public links omit URL credentials, query, and fragment', () {
    const server = ServerConfig(
      name: 'Server',
      baseUrl: 'https://username:password@example.test:8443/console?secret=key#private',
    );
    final share = SessionShare.fromJson({'enabled': true, 'token': 'shr123'});
    expect(
      share.publicUri(server).toString(),
      'https://example.test:8443/console/share/shr123',
    );
  });

  test('malformed share states cannot produce a public link', () async {
    for (final payload in [
      {'enabled': true},
      {'enabled': true, 'token': ''},
      {'enabled': true, 'token': '../private'},
      {'enabled': true, 'token': 'token?secret=x'},
      {'enabled': 'true', 'token': 'shr123'},
      {'enabled': false, 'token': 42},
    ]) {
      expect(() => SessionShare.fromJson(payload), throwsA(isA<AppError>()));
    }
    final client = MockClient(
      (_) async => http.Response('{"enabled":false,"token":""}', 200),
    );
    addTearDown(client.close);
    await expectLater(
      UhpService(client).setSessionShare(_server, 'session', enabled: true),
      throwsA(isA<AppError>()),
    );
  });

  Future<ProviderContainer> mount(
    WidgetTester tester,
    Future<http.Response> Function(http.Request) respond, {
    ConversationThread? thread,
  }) async {
    final client = MockClient(respond);
    final container = ProviderContainer(
      overrides: [httpClientProvider.overrideWithValue(client)],
    );
    container.read(selectedServerProvider.notifier).state = _server;
    container.read(threadProvider.notifier).state = thread ?? _thread();
    container.read(appDestinationProvider.notifier).state = AppDestination.chat;
    addTearDown(() {
      container.dispose();
      client.close();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) {
                final current = ref.watch(threadProvider);
                return current == null
                    ? const Text('Feed')
                    : SessionActionsMenu(thread: current);
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> open(WidgetTester tester, String item) async {
    await tester.tap(find.byTooltip('Session actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(item));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'opening restores without publishing; copy, native share, revoke',
    (tester) async {
      final requests = <http.Request>[];
      final nativeCalls = <MethodCall>[];
      String? copied;
      const channel = MethodChannel('dev.borges.uhp_android/session_files');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        nativeCalls.add(call);
        return null;
      });
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
      });
      await mount(tester, (request) async {
        requests.add(request);
        final enabled =
            request.method == 'GET' ||
            (jsonDecode(request.body) as Map)['enabled'] == true;
        return http.Response(
          jsonEncode({'enabled': enabled, 'token': 'shr123'}),
          200,
        );
      });
      await open(tester, 'Share…');
      expect(requests.map((r) => r.method), ['GET']);
      expect(find.text('https://example.test/share/shr123'), findsOneWidget);
      await tester.tap(find.text('Copy link'));
      await tester.pumpAndSettle();
      expect(copied, 'https://example.test/share/shr123');
      await tester.tap(find.text('Share link'));
      await tester.pumpAndSettle();
      expect(nativeCalls.single.method, 'shareText');
      expect((nativeCalls.single.arguments as Map)['text'], copied);
      await tester.tap(find.text('Revoke link'));
      await tester.pumpAndSettle();
      expect(requests.last.method, 'POST');
      expect(jsonDecode(requests.last.body), {'enabled': false});
      expect(find.text('https://example.test/share/shr123'), findsNothing);
      expect(find.text('Publish link'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      await open(tester, 'Share…');
      expect(requests.last.method, 'GET');
    },
  );

  testWidgets(
    'unpublished session requires explicit publish and errors remain retryable',
    (tester) async {
      final requests = <http.Request>[];
      await mount(tester, (request) async {
        requests.add(request);
        if (request.method == 'GET') {
          return http.Response('{"enabled":false,"token":""}', 200);
        }
        return http.Response('{"error":{"message":"Publish denied"}}', 403);
      });
      await open(tester, 'Share…');
      expect(requests.length, 1);
      expect(find.text('Copy link'), findsNothing);
      await tester.tap(find.text('Publish link'));
      await tester.pumpAndSettle();
      expect(requests.last.body, '{"enabled":true}');
      expect(find.textContaining('Publish denied'), findsOneWidget);
      expect(find.text('Copy link'), findsNothing);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(requests.last.method, 'GET');
    },
  );

  testWidgets(
    'confirmed cancel sends exact authenticated request and refreshes feed',
    (tester) async {
      final requests = <http.Request>[];
      final pending = _thread();
      final container = await mount(tester, (request) async {
        requests.add(request);
        return http.Response('', 204);
      }, thread: pending);
      await open(tester, 'Cancel session');
      expect(requests, isEmpty);
      await tester.tap(find.widgetWithText(FilledButton, 'Cancel session'));
      await tester.pumpAndSettle();
      final request = requests.single;
      expect(request.method, 'POST');
      expect(
        request.url.toString(),
        'https://example.test/api/harness/v1/sessions/session%2Fone/cancel',
      );
      expect(request.headers['authorization'], 'Bearer private-key');
      expect(request.headers['p-access-token'], 'edge-secret');
      expect(request.followRedirects, isFalse);
      expect(container.read(appDestinationProvider), AppDestination.feed);
      expect(container.read(sessionFeedRevisionProvider), 1);
      expect(container.read(threadProvider), isNull);
      expect(container.read(taskBusyProvider), isFalse);
      expect(pending.messages.single.status, TurnStatus.serverContinuing);
    },
  );

  testWidgets(
    'cancel rejects non-success without navigating or losing pending state',
    (tester) async {
      final pending = _thread();
      final container = await mount(
        tester,
        (_) async =>
            http.Response('{"error":{"message":"Cancel conflict"}}', 409),
        thread: pending,
      );
      await open(tester, 'Cancel session');
      await tester.tap(find.widgetWithText(FilledButton, 'Cancel session'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Cancel conflict'), findsOneWidget);
      expect(container.read(appDestinationProvider), AppDestination.chat);
      expect(container.read(threadProvider), same(pending));
      expect(container.read(sessionFeedRevisionProvider), 0);
      expect(container.read(taskBusyProvider), isFalse);
    },
  );

  testWidgets('confirmation rechecks busy, unsaved, and stale session guards', (
    tester,
  ) async {
    final requests = <http.Request>[];
    final container = await mount(tester, (request) async {
      requests.add(request);
      return http.Response('{}', 200);
    });
    await open(tester, 'Cancel session');
    final confirm = find.widgetWithText(FilledButton, 'Cancel session');
    container.read(taskBusyProvider.notifier).state = true;
    await tester.pump();
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
    container.read(taskBusyProvider.notifier).state = false;
    container.read(unsavedThreadProvider.notifier).state = _thread();
    await tester.pump();
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
    container.read(unsavedThreadProvider.notifier).state = null;
    container.read(threadProvider.notifier).state = _thread(
      sid: 'other',
      id: 'other',
    );
    await tester.pump();
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
    expect(requests, isEmpty);
    expect(container.read(sessionFeedRevisionProvider), 0);
  });

  testWidgets(
    'late cancel success never clears a different or unsaved conversation',
    (tester) async {
      final response = Completer<http.Response>();
      final container = await mount(tester, (_) => response.future);
      await open(tester, 'Cancel session');
      await tester.tap(find.widgetWithText(FilledButton, 'Cancel session'));
      await tester.pump();
      expect(container.read(taskBusyProvider), isTrue);
      final newer = _thread(sid: 'other', id: 'other');
      container.read(threadProvider.notifier).state = newer;
      container.read(unsavedThreadProvider.notifier).state = newer;
      response.complete(http.Response('{}', 200));
      await tester.pumpAndSettle();
      expect(container.read(threadProvider), same(newer));
      expect(container.read(unsavedThreadProvider), same(newer));
      expect(container.read(appDestinationProvider), AppDestination.chat);
      expect(container.read(sessionFeedRevisionProvider), 1);
      expect(container.read(taskBusyProvider), isFalse);
    },
  );

  testWidgets('local-only threads have no session menu', (tester) async {
    await mount(
      tester,
      (_) async => throw StateError('No network expected'),
      thread: _thread(sid: null),
    );
    expect(find.byTooltip('Session actions'), findsNothing);
  });
}
