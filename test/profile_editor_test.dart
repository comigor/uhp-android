import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uhp_android/main.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets(
    'profile edits persist without a save action or stable widget tree',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(const ProviderScope(child: UhpApp()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add server'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Name'),
        'Restart-safe profile',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Base URL'),
        'https://example.test',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'P-Access-Token'),
        'kept-token',
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(const ProviderScope(child: UhpApp()));
      await tester.pumpAndSettle();
      expect(find.text('Restart-safe profile'), findsOneWidget);
      await tester.tap(find.byTooltip('Edit server'));
      await tester.pumpAndSettle();
      final tokenField = tester.widget<TextField>(
        find.widgetWithText(TextField, 'P-Access-Token'),
      );
      expect(tokenField.controller!.text, 'kept-token');
      await tester.tap(find.byTooltip('Delete server'));
      await tester.pumpAndSettle();
      expect(find.text('No saved servers. Add one to begin.'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(const ProviderScope(child: UhpApp()));
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
      authMode: AuthMode.pangolin,
      accessTokenId: 'id',
      accessToken: 'token',
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
        child: const UhpApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Edit server'));
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
}
