import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uhp_android/main.dart';

Future<void> _mount(WidgetTester tester, List<ToolCall> tools) =>
    tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: ToolTimeline(tools: tools)),
        ),
      ),
    );

void main() {
  testWidgets('empty tools have no chip or argument content', (tester) async {
    await _mount(tester, const []);
    expect(find.byType(ActionChip), findsNothing);
    expect(find.byType(SelectableText), findsNothing);
  });

  testWidgets('collapsed tools reveal selectable pretty JSON only on demand', (
    tester,
  ) async {
    const args = '{"path":"lib/main.dart","nested":{"literal":"**text**"}}';
    await _mount(tester, const [ToolCall(name: 'read', args: args)]);
    expect(find.text('Tools (1)'), findsOneWidget);
    expect(find.byType(SelectableText), findsNothing);
    expect(find.text('read — lib/main.dart'), findsNothing);
    await tester.tap(find.text('Tools (1)'));
    await tester.pump();
    expect(find.text('read — lib/main.dart'), findsOneWidget);
    final arguments = tester.widget<SelectableText>(
      find.byType(SelectableText),
    );
    expect(
      arguments.data,
      const JsonEncoder.withIndent('  ').convert(jsonDecode(args)),
    );
    expect(arguments.style?.fontFamily, 'monospace');
    expect(find.byType(MarkdownBody), findsNothing);
    expect(find.text('Output'), findsNothing);
    await tester.tap(find.text('Tools (1)'));
    await tester.pump();
    expect(find.byType(SelectableText), findsNothing);
  });

  testWidgets(
    'summaries use key arguments and preserve invalid argument text',
    (tester) async {
      const invalid = '  **raw**\n  not JSON \t ';
      final long = List.filled(140, 'x').join();
      await _mount(tester, [
        const ToolCall(name: 'glob', args: '{"path":"src/**/*.dart"}'),
        const ToolCall(
          name: 'grep',
          args: '{"pattern":"one\\n  two","path":"ignored"}',
        ),
        const ToolCall(
          name: 'bash',
          args: '{"command":"echo hello","timeout":5}',
        ),
        const ToolCall(name: 'custom', args: '{"key":true}'),
        const ToolCall(name: 'raw', args: invalid),
        ToolCall(name: 'read', args: jsonEncode({'path': long})),
      ]);
      await tester.tap(find.text('Tools (6)'));
      await tester.pump();
      expect(find.text('glob — src/**/*.dart'), findsOneWidget);
      expect(find.text('grep — one two'), findsOneWidget);
      expect(find.text('bash — echo hello'), findsOneWidget);
      expect(find.text('custom — {"key":true}'), findsOneWidget);
      expect(find.text('raw — **raw** not JSON'), findsOneWidget);
      expect(find.text(invalid), findsOneWidget);
      expect(
        find.text('read — ${List.filled(99, 'x').join()}…'),
        findsOneWidget,
      );
      expect(find.byType(MarkdownBody), findsNothing);
    },
  );

  testWidgets(
    'each turn expands independently and retains state after remount',
    (tester) async {
      final bucket = PageStorageBucket();
      const first = ToolTimeline(
        key: ValueKey(('thread', 1)),
        tools: [ToolCall(name: 'read', args: '{"path":"first"}')],
      );
      const second = ToolTimeline(
        key: ValueKey(('thread', 2)),
        tools: [ToolCall(name: 'read', args: '{"path":"second"}')],
      );
      Future<void> mount(bool showFirst) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PageStorage(
              bucket: bucket,
              child: SingleChildScrollView(
                child: Column(children: [if (showFirst) first, second]),
              ),
            ),
          ),
        ),
      );
      await mount(true);
      await tester.tap(
        find.descendant(
          of: find.byWidget(first),
          matching: find.byType(ActionChip),
        ),
      );
      await tester.pump();
      expect(find.text('read — first'), findsOneWidget);
      expect(find.text('read — second'), findsNothing);
      await mount(false);
      await mount(true);
      expect(find.text('read — first'), findsOneWidget);
      expect(find.text('read — second'), findsNothing);
      await tester.tap(
        find.descendant(
          of: find.byWidget(second),
          matching: find.byType(ActionChip),
        ),
      );
      await tester.pump();
      expect(find.text('read — first'), findsOneWidget);
      expect(find.text('read — second'), findsOneWidget);
    },
  );
}
