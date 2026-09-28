import 'dart:async';
import 'dart:convert';

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
ConversationThread _thread({
  bool linked = true,
  String id = 'local',
  TurnStatus status = TurnStatus.completed,
}) => ConversationThread(
  id: id,
  title: 'Conversation',
  server: _server,
  harnessId: 'h1',
  harnessName: 'Research',
  serverSessionId: linked ? 's1' : null,
  serverSessionStatus: 'completed',
  serverLastResponseId: 'r1',
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
  messages: [
    ThreadMessage(
      role: 'assistant',
      text: 'Response',
      status: status,
      responseId: 'r1',
      createdAt: DateTime.utc(2026),
    ),
  ],
);

class _Platform extends SessionFilePlatform {
  final discarded = <PickedAttachment>[];
  Completer<List<PickedAttachment>>? pending;
  @override
  Future<List<PickedAttachment>> pickAttachments() async =>
      pending?.future ??
      [
        const PickedAttachment(
          path: '/private/attachments/notes.txt',
          name: 'notes.txt',
          size: 12,
          mediaType: 'text/plain',
        ),
      ];
  @override
  Future<void> discardAttachments(List<PickedAttachment> attachments) async {
    discarded.addAll(attachments);
  }
}

void main() {
  Future<
    ({ProviderContainer container, _Platform platform, List<Uri> requests})
  >
  mount(WidgetTester tester, ConversationThread thread) async {
    SharedPreferences.setMockInitialValues({
      ServerStore.key: jsonEncode([_server.toJson()]),
    });
    final requests = <Uri>[];
    final client = MockClient((request) async {
      requests.add(request.url);
      if (request.url.path.endsWith('/files')) {
        return http.Response(
          '{"detail":"no workspace for this session yet — run a task first"}',
          404,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      throw StateError('Unexpected request ${request.url}');
    });
    final platform = _Platform();
    final container = ProviderContainer(
      overrides: [
        httpClientProvider.overrideWithValue(client),
        sessionFilePlatformProvider.overrideWithValue(platform),
      ],
    );
    container.read(threadProvider.notifier).state = thread;
    container.read(appDestinationProvider.notifier).state = AppDestination.chat;
    await tester.runAsync(() => container.read(serversProvider.future));
    container.read(selectedServerProvider.notifier).state = _server;
    addTearDown(() {
      container.dispose();
      client.close();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          scaffoldMessengerKey: container.read(appScaffoldMessengerKeyProvider),
          home: const Scaffold(body: TasksScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (container: container, platform: platform, requests: requests);
  }

  testWidgets(
    'local-only chat hides files and share and disables attachment picker',
    (tester) async {
      await mount(tester, _thread(linked: false, status: TurnStatus.failed));
      expect(find.text('Files'), findsNothing);
      expect(find.text('View files'), findsNothing);
      expect(find.byType(SessionActionsMenu), findsNothing);
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is IconButton &&
                    widget.tooltip == 'attachments need a server session',
              ),
            )
            .onPressed,
        isNull,
      );
    },
  );

  for (final status in [TurnStatus.failed, TurnStatus.cancelled]) {
    testWidgets(
      '${status.name} server turn exposes changed workspace diagnostics',
      (tester) async {
        final fixture = await mount(tester, _thread(status: status));
        await tester.ensureVisible(find.text('View files'));
        await tester.tap(find.text('View files'));
        await tester.pumpAndSettle();
        expect(find.byType(SessionFilesSheet), findsOneWidget);
        expect(fixture.requests.single.queryParameters['changed'], 'true');
        expect(
          fixture.requests.single.path,
          '/api/harness/v1/sessions/s1/files',
        );
      },
    );
  }

  testWidgets(
    'picked files have removable chips and private cache copies are discarded',
    (tester) async {
      final fixture = await mount(tester, _thread());
      await tester.tap(find.byTooltip('Attach files'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(InputChip, 'notes.txt'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.widgetWithText(InputChip, 'notes.txt'),
          matching: find.byTooltip('Delete'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.widgetWithText(InputChip, 'notes.txt'), findsNothing);
      expect(fixture.platform.discarded.map((a) => a.name), ['notes.txt']);
      expect(fixture.requests, isEmpty);
    },
  );

  testWidgets('a picker result cannot attach to a different chat', (
    tester,
  ) async {
    final fixture = await mount(tester, _thread());
    final result = Completer<List<PickedAttachment>>();
    fixture.platform.pending = result;
    await tester.tap(find.byTooltip('Attach files'));
    await tester.pump();
    fixture.container.read(threadProvider.notifier).state = _thread(
      id: 'other',
    );
    await tester.pump();
    result.complete([
      const PickedAttachment(
        path: '/private/attachments/stale.txt',
        name: 'stale.txt',
        size: 5,
      ),
    ]);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(InputChip, 'stale.txt'), findsNothing);
    expect(fixture.platform.discarded.map((a) => a.name), ['stale.txt']);
  });

  testWidgets('busy and unsaved states prevent selecting attachments', (
    tester,
  ) async {
    final fixture = await mount(tester, _thread());
    fixture.container.read(taskBusyProvider.notifier).state = true;
    await tester.pump();
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) =>
                  widget is IconButton && widget.tooltip == 'Attach files',
            ),
          )
          .onPressed,
      isNull,
    );
    fixture.container.read(taskBusyProvider.notifier).state = false;
    fixture.container.read(unsavedThreadProvider.notifier).state = _thread();
    await tester.pump();
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) =>
                  widget is IconButton && widget.tooltip == 'Attach files',
            ),
          )
          .onPressed,
      isNull,
    );
    expect(fixture.requests, isEmpty);
  });
}
