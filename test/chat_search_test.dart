import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uhp_android/main.dart';
import 'package:uhp_android/message_content.dart';

const _server = ServerConfig(
  id: 'server',
  name: 'Server',
  baseUrl: 'https://example.test',
);

ConversationThread _thread(
  List<String> texts, {
  bool linked = false,
  String id = 'chat',
}) => ConversationThread(
  id: id,
  title: 'Conversation',
  server: _server,
  harnessId: 'harness',
  harnessName: 'Harness',
  serverSessionId: linked ? 'session' : null,
  serverSessionStatus: 'completed',
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
  messages: [
    for (var index = 0; index < texts.length; index++)
      ThreadMessage(
        role: index.isEven ? 'assistant' : 'user',
        text: texts[index],
        createdAt: DateTime.utc(2026).add(Duration(seconds: index)),
      ),
  ],
);

final _query = find.byKey(const ValueKey('chat-search-query'));
final _count = find.byKey(const ValueKey('chat-search-count'));
Finder _paragraph(String text) => find.byWidgetPredicate(
  (widget) => widget is RichText && widget.text.toPlainText() == text,
);

void main() {
  Future<ProviderContainer> mount(
    WidgetTester tester,
    ConversationThread thread,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final client = MockClient((request) async {
      throw StateError('Search must not request ${request.url}');
    });
    final container = ProviderContainer(
      overrides: [httpClientProvider.overrideWithValue(client)],
    );
    container.read(threadProvider.notifier).state = thread;
    container.read(chatSearchOpenProvider.notifier).state = true;
    addTearDown(() {
      container.dispose();
      client.close();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            appBar: AppBar(title: const Text('Chat')),
            body: const TasksScreen(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  void expectCount(WidgetTester tester, String count) {
    expect(tester.widget<Text>(_count).data, count);
  }

  for (final linked in [false, true]) {
    testWidgets(
      '${linked ? 'linked' : 'local'} search counts literal occurrences and wraps',
      (tester) async {
        await mount(
          tester,
          _thread([
            'Older [a] response',
            'Newest [A] then [a]',
          ], linked: linked),
        );
        await tester.enterText(_query, '[a]');
        await tester.pumpAndSettle();
        expectCount(tester, '1/3');
        expect(find.byType(MessageContent), findsNothing);
        final rich = tester.widget<RichText>(_paragraph('Newest [A] then [a]'));
        final spans = (rich.text as TextSpan).children!
            .whereType<TextSpan>()
            .toList();
        final highlighted = spans
            .where((span) => span.style?.backgroundColor != null)
            .toList();
        expect(highlighted.map((span) => span.text), ['[A]', '[a]']);
        expect(
          highlighted.first.style!.backgroundColor,
          isNot(highlighted.last.style!.backgroundColor),
        );
        await tester.tap(find.byTooltip('Previous match'));
        await tester.pumpAndSettle();
        expectCount(tester, '3/3');
        await tester.tap(find.byTooltip('Next match'));
        await tester.pumpAndSettle();
        expectCount(tester, '1/3');
        await tester.tap(find.byTooltip('Next match'));
        await tester.pumpAndSettle();
        expectCount(tester, '2/3');
      },
    );
  }

  testWidgets(
    'X and Escape clear search and restore normal message rendering',
    (tester) async {
      final container = await mount(tester, _thread(['**needle** needle']));
      await tester.enterText(_query, 'needle');
      await tester.pumpAndSettle();
      expectCount(tester, '1/2');
      await tester.tap(find.byTooltip('Close chat search'));
      await tester.pumpAndSettle();
      expect(_query, findsNothing);
      expect(find.byType(MessageContent), findsOneWidget);
      container.read(chatSearchOpenProvider.notifier).state = true;
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(_query).controller!.text, isEmpty);
      expectCount(tester, '0/0');
      await tester.enterText(_query, 'NEEDLE');
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(_query, findsNothing);
      container.read(chatSearchOpenProvider.notifier).state = true;
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(_query).controller!.text, isEmpty);
      expectCount(tester, '0/0');
    },
  );

  testWidgets(
    'far variable-height rows and occurrences inside one tall row are revealed lazily',
    (tester) async {
      final oldest =
          'Needle at start\n${List.filled(100, 'a long row with more text').join('\n')}\nNeedle at end';
      await mount(
        tester,
        _thread([
          oldest,
          for (var i = 1; i < 250; i++)
            'row $i\n${List.filled(i % 9 + 1, 'variable height').join('\n')}',
          'Newest needle',
        ]),
      );
      await tester.enterText(_query, 'needle');
      await tester.pumpAndSettle();
      expectCount(tester, '1/3');
      await tester.tap(find.byTooltip('Next match'));
      await tester.pumpAndSettle();
      expectCount(tester, '2/3');
      expect(_paragraph(oldest), findsOneWidget);
      expect(find.byType(Card).evaluate().length, lessThan(30));
      final barTop = tester.getTopLeft(_query).dy;
      await tester.tap(find.byTooltip('Next match'));
      await tester.pumpAndSettle();
      expectCount(tester, '3/3');
      final paragraph = tester.renderObject<RenderParagraph>(
        _paragraph(oldest),
      );
      final start = oldest.lastIndexOf('Needle');
      final box = paragraph
          .getBoxesForSelection(
            TextSelection(baseOffset: start, extentOffset: start + 6),
          )
          .first;
      final y = paragraph.localToGlobal(Offset(0, box.top)).dy;
      expect(y, greaterThan(tester.getBottomLeft(_query).dy));
      expect(
        y,
        lessThan(
          tester.view.physicalSize.height / tester.view.devicePixelRatio,
        ),
      );
      expect(tester.getTopLeft(_query).dy, barTop);
      expect(find.byType(Card).evaluate().length, lessThan(30));
    },
  );

  testWidgets(
    'empty and unmatched queries disable navigation; changed messages reconcile active match',
    (tester) async {
      final container = await mount(tester, _thread(['needle needle']));
      expectCount(tester, '0/0');
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.keyboard_arrow_down),
            )
            .onPressed,
        isNull,
      );
      await tester.enterText(_query, 'absent');
      await tester.pumpAndSettle();
      expectCount(tester, '0/0');
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.keyboard_arrow_up),
            )
            .onPressed,
        isNull,
      );
      await tester.enterText(_query, 'needle');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Next match'));
      await tester.pumpAndSettle();
      container.read(threadProvider.notifier).state = _thread(['needle']);
      await tester.pumpAndSettle();
      expectCount(tester, '1/1');
      container.read(threadProvider.notifier).state = _thread([]);
      await tester.pumpAndSettle();
      expectCount(tester, '0/0');
      expect(find.text('No task history yet.'), findsOneWidget);
      await tester.enterText(_query, '');
      await tester.pumpAndSettle();
      expectCount(tester, '0/0');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'changing thread or disposing with a queued jump never scrolls stale state',
    (tester) async {
      final container = await mount(tester, _thread(['needle']));
      await tester.enterText(_query, 'needle');
      container.read(threadProvider.notifier).state = _thread([
        'different chat',
      ], id: 'other');
      await tester.pumpAndSettle();
      expect(_query, findsNothing);
      expect(find.byType(MessageContent), findsOneWidget);
      container.read(chatSearchOpenProvider.notifier).state = true;
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(_query).controller!.text, isEmpty);
      await tester.enterText(_query, 'different');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
