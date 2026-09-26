import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uhp_android/main.dart';

void main() {
  testWidgets('shows app shell', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: UhpApp()));
    expect(find.text('UHP Android'), findsOneWidget);
    expect(find.text('Servers'), findsWidgets);
    expect(find.text('Harnesses'), findsWidgets);
    expect(find.text('Tasks'), findsWidgets);
  });
}
