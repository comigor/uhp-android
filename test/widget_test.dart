import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uhp_android/main.dart';

void main() {
  testWidgets('first launch opens the server editor without navigation tabs', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const ProviderScope(child: UhpApp()));
    await tester.pumpAndSettle();

    expect(find.byType(ServerEditor), findsOneWidget);
    expect(
      find.widgetWithText(TextField, 'API key (required)'),
      findsOneWidget,
    );
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byType(TabBar), findsNothing);
  });
}
