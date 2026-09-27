import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uhp_android/main.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _ProfileTestApp extends ConsumerWidget {
  const _ProfileTestApp();

  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp(
    scaffoldMessengerKey: ref.watch(appScaffoldMessengerKeyProvider),
    home: const Scaffold(body: SettingsScreen()),
  );
}

void main() {
  testWidgets(
    'profile edits persist without a save action or stable widget tree',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(const ProviderScope(child: _ProfileTestApp()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add server'));
      await tester.pumpAndSettle();
      expect(find.text('API key required'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'Name'),
        'Restart-safe profile',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Base URL'),
        'https://example.test',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'API key (required)'),
        'fake-editor-api-key',
      );
      await tester.pumpAndSettle();
      expect(find.text('API key required'), findsNothing);
      await tester.enterText(
        find.widgetWithText(TextField, 'P-Access-Token-Id'),
        'fake-edge-token-id',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'P-Access-Token'),
        'fake-edge-token',
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(const ProviderScope(child: _ProfileTestApp()));
      await tester.pumpAndSettle();
      expect(find.text('Restart-safe profile'), findsOneWidget);
      await tester.tap(find.byTooltip('Edit server'));
      await tester.pumpAndSettle();
      final keyField = tester.widget<TextField>(
        find.widgetWithText(TextField, 'API key (required)'),
      );
      expect(keyField.controller!.text, 'fake-editor-api-key');
      expect(keyField.obscureText, isTrue);
      expect(
        tester
            .widget<TextField>(
              find.widgetWithText(TextField, 'P-Access-Token-Id'),
            )
            .controller!
            .text,
        'fake-edge-token-id',
      );
      final tokenField = tester.widget<TextField>(
        find.widgetWithText(TextField, 'P-Access-Token'),
      );
      expect(tokenField.controller!.text, 'fake-edge-token');
      await tester.tap(find.byTooltip('Delete server'));
      await tester.pumpAndSettle();
      expect(find.text('No saved servers. Add one to begin.'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(const ProviderScope(child: _ProfileTestApp()));
      await tester.pumpAndSettle();
      expect(find.text('No saved servers. Add one to begin.'), findsOneWidget);
    },
  );

  testWidgets('connection result persists after leaving the editor', (
    tester,
  ) async {
    const server = ServerConfig(
      id: 'server',
      name: 'Server',
      baseUrl: 'https://example.test',
      apiKey: 'fake-connection-api-key',
      accessTokenId: 'fake-edge-token-id',
      accessToken: 'fake-edge-token',
    );
    SharedPreferences.setMockInitialValues({
      ServerStore.key: jsonEncode([server.toJson()]),
    });
    final response = Completer<http.Response>();
    final client = MockClient((_) => response.future);
    addTearDown(client.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [httpClientProvider.overrideWithValue(client)],
        child: const _ProfileTestApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Edit server'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Test connection'),
      200,
      scrollable: find
          .descendant(
            of: find.byType(ListView).last,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Test connection'));
    await tester.pump();
    await tester.pageBack();
    await tester.pumpAndSettle();
    response.complete(http.Response('{"data":[]}', 200));
    await tester.pumpAndSettle();
    final saved = await ServerStore(SharedPreferences.getInstance).load();
    expect(saved.single.testResult, '0 harnesses');
    expect(find.textContaining('0 harnesses'), findsOneWidget);
  });

  testWidgets('legacy profile requires a key despite a saved success', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      ServerStore.key: jsonEncode([
        {
          'id': 'legacy',
          'name': 'Legacy server',
          'baseUrl': 'https://example.test',
          'username': 'fake-legacy-user',
          'password': 'fake-legacy-password',
          'testResult': '4 harnesses',
        },
      ]),
    });
    var requests = 0;
    final client = MockClient((_) async {
      requests++;
      return http.Response('{"data":[]}', 200);
    });
    addTearDown(client.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [httpClientProvider.overrideWithValue(client)],
        child: const _ProfileTestApp(),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(_ProfileTestApp)),
    );
    expect(find.textContaining('API key required'), findsOneWidget);
    expect(find.textContaining('4 harnesses'), findsNothing);
    await tester.tap(find.text('Legacy server'));
    await tester.pumpAndSettle();
    expect(find.byType(ServerEditor), findsOneWidget);
    expect(container.read(selectedServerProvider), isNull);
    expect(find.text('API key required'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'API key (required)'),
      '   ',
    );
    await tester.pumpAndSettle();
    expect(find.text('API key required'), findsOneWidget);
    await tester.ensureVisible(find.text('Test connection'));
    await tester.tap(find.text('Test connection'));
    await tester.pumpAndSettle();
    expect(requests, 0);
    final saved = await ServerStore(SharedPreferences.getInstance).load();
    expect(saved.single.testResult, 'API key required');
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(container.read(selectedServerProvider), isNull);
    expect(
      find.descendant(
        of: find.byType(ListTile),
        matching: find.textContaining('API key required'),
      ),
      findsOneWidget,
    );
  });

  for (final scenario in [
    (
      name: 'edge redirect',
      status: 303,
      body: '<html>Edge sign-in</html>',
      message:
          'Edge sign-in required: add the Pangolin token pair for this server.',
    ),
    (
      name: 'API key rejection',
      status: 401,
      body: '{"error":{"type":"authentication_error"}}',
      message: 'Server rejected the API key.',
    ),
    (
      name: 'unclassified unauthorized response',
      status: 401,
      body: '<html>Edge access denied</html>',
      message: 'HTTP 401: <html>Edge access denied</html>',
    ),
  ]) {
    testWidgets('connection test displays ${scenario.name}', (tester) async {
      const server = ServerConfig(
        id: 'error-server',
        name: 'Error server',
        baseUrl: 'https://example.test',
        apiKey: 'fake-error-api-key',
      );
      SharedPreferences.setMockInitialValues({
        ServerStore.key: jsonEncode([server.toJson()]),
      });
      var requests = 0;
      final client = MockClient.streaming((request, body) async {
        requests++;
        await body.drain<void>();
        expect(request.url.path, '/api/harness/v1/harnesses');
        expect(request.headers['Authorization'], 'Bearer fake-error-api-key');
        // Give cancellation a future in this test's zone, as a real transport does.
        final response = StreamController<List<int>>(onCancel: () async {});
        response.add(utf8.encode(scenario.body));
        unawaited(response.close());
        return http.StreamedResponse(response.stream, scenario.status);
      });
      addTearDown(client.close);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [httpClientProvider.overrideWithValue(client)],
          child: const _ProfileTestApp(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Edit server'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Test connection'));
      await tester.tap(find.text('Test connection'));
      await tester.pumpAndSettle();
      expect(requests, 1);
      final saved = await ServerStore(SharedPreferences.getInstance).load();
      expect(saved.single.testResult, scenario.message);
      await tester.scrollUntilVisible(
        find.descendant(
          of: find.byType(ListView).last,
          matching: find.text(scenario.message),
        ),
        100,
        scrollable: find
            .descendant(
              of: find.byType(ListView).last,
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(ListView).last,
          matching: find.text(scenario.message),
        ),
        findsOneWidget,
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(ListTile),
          matching: find.textContaining(scenario.message),
        ),
        findsOneWidget,
      );
    });
  }
}
