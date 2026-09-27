import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uhp_android/main.dart';
import 'package:uhp_android/update_ui.dart';
import 'package:uhp_android/updater.dart';

const _server = ServerConfig(
  id: 'first',
  name: 'First server',
  baseUrl: 'https://first.test',
  apiKey: 'fake-settings-key',
);
const _otherServer = ServerConfig(
  id: 'second',
  name: 'Second server',
  baseUrl: 'https://second.test',
  apiKey: 'fake-settings-key',
);

void main() {
  Future<ProviderContainer> mount(
    WidgetTester tester, {
    http.Client? client,
    ServerConfig? selectedServer,
  }) async {
    SharedPreferences.setMockInitialValues({
      ServerStore.key: jsonEncode([_server.toJson(), _otherServer.toJson()]),
    });
    final httpClient =
        client ?? MockClient((_) async => http.Response('{"data":[]}', 200));
    final container = ProviderContainer(
      overrides: [httpClientProvider.overrideWithValue(httpClient)],
    );
    addTearDown(container.dispose);
    addTearDown(httpClient.close);
    container.read(appDestinationProvider.notifier).state =
        AppDestination.settings;
    container.read(selectedServerProvider.notifier).state = selectedServer;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          scaffoldMessengerKey: container.read(appScaffoldMessengerKeyProvider),
          home: const Scaffold(body: SettingsScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('all settings sections and updater share one scrollable page', (
    tester,
  ) async {
    await mount(tester);
    expect(find.text('Servers'), findsOneWidget);
    expect(find.text('Harnesses'), findsOneWidget);
    await tester.ensureVisible(find.text('Updater'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(UpdateMenu));
    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    expect(find.text('Check for updates'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Version $appVersion'));
    expect(find.text('About'), findsOneWidget);
    expect(find.text('Version $appVersion'), findsOneWidget);
  });

  testWidgets(
    'server selection returns to feed and survives preferences reload',
    (tester) async {
      final container = await mount(tester);
      await tester.tap(find.text('Second server'));
      await tester.pumpAndSettle();
      expect(container.read(appDestinationProvider), AppDestination.feed);
      expect(container.read(selectedServerProvider)?.id, _otherServer.id);
      container.invalidate(appPreferencesProvider);
      final preferences = await container.read(appPreferencesProvider.future);
      expect(preferences.lastServerId, _otherServer.id);

      await tester.tap(find.byTooltip('Edit server').last);
      await tester.pumpAndSettle();
      expect(find.byType(ServerEditor), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Base URL'))
            .controller!
            .text,
        _otherServer.baseUrl,
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);
    },
  );

  testWidgets(
    'settings model editor PUT preserves complete harness configuration',
    (tester) async {
      var detail = <String, dynamic>{
        'id': 'research',
        'name': 'Research',
        'base': 'required-base',
        'defaultModel': 'model-a',
        'maxStep': 12,
        'timeoutSeconds': 90,
        'tools': [
          {
            'name': 'search',
            'config': {'limit': 4},
          },
        ],
        'futureOption': {'enabled': true},
      };
      final original = Map<String, dynamic>.from(detail);
      Map<String, dynamic>? saved;
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/models')) {
          return http.Response('{"models":["model-a","model-b"]}', 200);
        }
        if (request.url.path.endsWith('/harnesses/research')) {
          if (request.method == 'PUT') {
            saved = Map<String, dynamic>.from(jsonDecode(request.body) as Map);
            detail = saved!;
          }
          return http.Response(jsonEncode({'data': detail}), 200);
        }
        if (request.url.path.endsWith('/harnesses')) {
          return http.Response(
            jsonEncode({
              'data': [detail],
            }),
            200,
          );
        }
        throw StateError(
          'Unexpected request: ${request.method} ${request.url}',
        );
      });
      await mount(tester, client: client, selectedServer: _server);
      await tester.ensureVisible(find.byTooltip('Edit default model'));
      await tester.tap(find.byTooltip('Edit default model'));
      await tester.pumpAndSettle();
      expect(find.text('Default model · Research'), findsOneWidget);
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('model-b').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(saved, {...original, 'defaultModel': 'model-b'});
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.textContaining('model-b'), findsOneWidget);
    },
  );
}
