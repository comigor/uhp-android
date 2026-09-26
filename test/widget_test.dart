import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uhp_android/main.dart';

void main() {
  testWidgets('renders bottom navigation destinations', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: UhpApp()));

    expect(find.text('Servers'), findsOneWidget);
    expect(find.text('Harnesses'), findsOneWidget);
    expect(find.text('Tasks'), findsOneWidget);
  });
}
