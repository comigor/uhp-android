import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uhp_android/main.dart';
import 'package:uhp_android/message_content.dart';

Future<void> _mount(
  WidgetTester tester,
  String text, {
  String role = 'assistant',
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: MessageContent(role: role, text: text),
      ),
    ),
  ),
);

Iterable<TextSpan> _spans(InlineSpan span) sync* {
  if (span is TextSpan) {
    yield span;
    for (final child in span.children ?? const <InlineSpan>[]) {
      yield* _spans(child);
    }
  }
}

void main() {
  testWidgets('complete fences preserve code and copy exactly the code body', (
    tester,
  ) async {
    const code = 'if (a < b && c > 0) {\n  print("hi");  \n}\n\n';
    String? copied;
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
        SystemChannels.platform,
        null,
      );
    });
    await _mount(tester, 'Before\n\n```dart\n$code```\n\nAfter');
    expect(find.text('Before', findRichText: true), findsOneWidget);
    expect(find.text('After', findRichText: true), findsOneWidget);
    expect(find.widgetWithText(Chip, 'dart'), findsOneWidget);
    final codeText = find.text(code);
    expect(codeText, findsOneWidget);
    expect(tester.widget<Text>(codeText).style?.fontFamily, 'monospace');
    await tester.tap(find.byTooltip('Copy code'));
    await tester.pump();
    expect(copied, code);
  });

  testWidgets(
    'unfinished streamed fences render and become complete markdown',
    (tester) async {
      await _mount(tester, '```python\nprint("par');
      expect(find.widgetWithText(Chip, 'python'), findsOneWidget);
      expect(find.text('print("par\n'), findsOneWidget);
      await _mount(tester, '```python\nprint("partial")\n```\n\n**Finished**');
      expect(find.text('print("partial")\n'), findsOneWidget);
      expect(find.text('Finished', findRichText: true), findsOneWidget);
      expect(find.byTooltip('Copy code'), findsOneWidget);
    },
  );

  testWidgets('prompts remain selectable literal text instead of markdown', (
    tester,
  ) async {
    const prompt =
        '# Heading\n**literal** [link](https://example.test)\n```dart\nx\n```';
    await _mount(tester, prompt, role: 'user');
    expect(find.text(prompt), findsOneWidget);
    expect(find.byType(SelectableText), findsOneWidget);
    expect(find.byType(MarkdownBody), findsNothing);
    expect(find.byTooltip('Copy code'), findsNothing);
  });

  testWidgets(
    'assistant formatting renders headings emphasis lists and tables',
    (tester) async {
      await _mount(
        tester,
        '# Heading\n\n**Bold** and *italic* and `inline`\n\n'
        '- First item\n- Second item\n\n'
        '| Name | Value |\n| --- | --- |\n| alpha | beta |',
      );
      expect(find.text('Heading', findRichText: true), findsOneWidget);
      expect(find.text('First item', findRichText: true), findsOneWidget);
      expect(find.text('Second item', findRichText: true), findsOneWidget);
      expect(find.text('alpha', findRichText: true), findsOneWidget);
      expect(find.text('beta', findRichText: true), findsOneWidget);
      final spans = tester
          .widgetList<SelectableText>(find.byType(SelectableText))
          .where((text) => text.textSpan != null)
          .expand((text) => _spans(text.textSpan!));
      expect(
        spans.any(
          (span) =>
              span.text == 'Bold' && span.style?.fontWeight == FontWeight.bold,
        ),
        isTrue,
      );
      expect(
        spans.any(
          (span) =>
              span.text == 'italic' &&
              span.style?.fontStyle == FontStyle.italic,
        ),
        isTrue,
      );
      expect(
        spans.any(
          (span) =>
              span.text == 'inline' && span.style?.fontFamily == 'monospace',
        ),
        isTrue,
      );
      expect(find.byTooltip('Copy code'), findsNothing);
    },
  );

  testWidgets('links show a selectable URL and copy without launching it', (
    tester,
  ) async {
    const url = 'https://example.test/guide?q=one&next=two';
    String? copied;
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
        SystemChannels.platform,
        null,
      );
    });
    await _mount(tester, '[Read guide]($url)');
    await tester.tap(find.text('Read guide', findRichText: true));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AlertDialog, 'Link'), findsOneWidget);
    expect(find.widgetWithText(SelectableText, url), findsOneWidget);
    await tester.tap(find.text('Copy link'));
    await tester.pump();
    expect(copied, url);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('remote and local images remain plain resource descriptions', (
    tester,
  ) async {
    await _mount(
      tester,
      '![remote](https://example.test/image.png)\n\n![local](file:///private/image.png)',
    );
    expect(
      find.text('[Image: remote] https://example.test/image.png'),
      findsOneWidget,
    );
    expect(
      find.text('[Image: local] file:///private/image.png'),
      findsOneWidget,
    );
    expect(find.byType(Image), findsNothing);
  });

  testWidgets(
    'streaming updates leave historical markdown and scroll state intact',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final now = DateTime.utc(2026);
      final history =
          '```text\n${List.filled(60, 'historical').join(' ')}\n```';
      container.read(threadProvider.notifier).state = ConversationThread(
        id: 'local',
        title: 'History',
        server: const ServerConfig(
          id: 'test',
          name: 'Test',
          baseUrl: 'https://example.test',
          apiKey: '',
        ),
        harnessId: 'h',
        harnessName: 'Harness',
        createdAt: now,
        updatedAt: now,
        messages: [
          ThreadMessage(role: 'assistant', text: history, createdAt: now),
        ],
      );
      container.read(liveTurnProvider.notifier).state = const LiveTurn(
        input: '**Plain prompt**',
        progress: TurnProgress(text: '**Live**'),
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: ThemeData(platform: TargetPlatform.android),
            home: const Scaffold(body: TasksScreen()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final historical = find.byWidgetPredicate(
        (widget) => widget is MarkdownBody && widget.data == history,
      );
      final horizontal = find.descendant(
        of: historical,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              widget.axisDirection == AxisDirection.right,
        ),
      );
      await tester.ensureVisible(horizontal);
      await tester.pumpAndSettle();
      await tester.drag(horizontal, const Offset(-180, 0));
      await tester.pumpAndSettle();
      final scrollState = tester.state<ScrollableState>(horizontal);
      final offset = scrollState.position.pixels;
      expect(offset, greaterThan(0));
      for (final text in ['**Live more**', '**Live complete**']) {
        container.read(liveTurnProvider.notifier).state = LiveTurn(
          input: '**Plain prompt**',
          progress: TurnProgress(text: text),
        );
        await tester.pump();
        expect(
          tester.state<ScrollableState>(horizontal).position.pixels,
          offset,
        );
      }
      expect(find.text('Live complete', findRichText: true), findsOneWidget);
      expect(find.text('**Plain prompt**'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
