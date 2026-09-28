import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uhp_android/main.dart';
import 'package:uhp_android/message_content.dart';

void main() {
  testWidgets(
    'working placeholder yields to first content and caret ends with stream',
    (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(liveTurnProvider.notifier).state = LiveTurn(
        input: 'Prompt',
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: ActiveTurnCard())),
        ),
      );
      expect(find.text('Agent is working…'), findsOneWidget);
      expect(find.byKey(const ValueKey('streaming-caret')), findsNothing);
      container.read(liveTurnProvider.notifier).state = LiveTurn(
        input: 'Prompt',
        progress: const TurnProgress(tools: ['read']),
      );
      await tester.pump();
      expect(find.text('Agent is working…'), findsOneWidget);
      container.read(liveTurnProvider.notifier).state = LiveTurn(
        input: 'Prompt',
        progress: const TurnProgress(text: 'First delta'),
      );
      await tester.pump();
      expect(find.text('Agent is working…'), findsNothing);
      expect(find.text('First delta', findRichText: true), findsOneWidget);
      expect(find.byKey(const ValueKey('streaming-caret')), findsOneWidget);
      container.read(liveTurnProvider.notifier).state = LiveTurn(
        input: 'Prompt',
        progress: const TurnProgress(text: 'First delta'),
        stopping: true,
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('streaming-caret')), findsNothing);
      expect(find.text('First delta', findRichText: true), findsOneWidget);
      container.read(liveTurnProvider.notifier).state = null;
      await tester.pump();
      expect(find.text('Agent is working…'), findsNothing);
      expect(find.byKey(const ValueKey('streaming-caret')), findsNothing);
    },
  );

  testWidgets('caret leaves closed and unfinished Markdown fences intact', (
    tester,
  ) async {
    const complete = '```dart\nfinal value = 1;\n```';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MessageContent(
            role: 'assistant',
            text: complete,
            streaming: true,
          ),
        ),
      ),
    );
    expect(find.text('final value = 1;\n'), findsOneWidget);
    expect(find.widgetWithText(Chip, 'dart'), findsOneWidget);
    expect(find.byTooltip('Copy code'), findsOneWidget);
    expect(find.byKey(const ValueKey('streaming-caret')), findsOneWidget);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MessageContent(
            role: 'assistant',
            text: '```dart\nfinal value =',
            streaming: true,
          ),
        ),
      ),
    );
    expect(find.text('final value =\n'), findsOneWidget);
    expect(find.widgetWithText(Chip, 'dart'), findsOneWidget);
    expect(find.byKey(const ValueKey('streaming-caret')), findsOneWidget);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MessageContent(role: 'assistant', text: complete),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('streaming-caret')), findsNothing);
    expect(find.text('final value = 1;\n'), findsOneWidget);
    expect(find.byType(MarkdownBody), findsOneWidget);
  });
}
