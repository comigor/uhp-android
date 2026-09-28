import 'package:flutter/material.dart';
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

ConversationThread _thread(List<String> texts) => ConversationThread(
  id: 'chat',
  title: 'Conversation',
  server: _server,
  harnessId: 'harness',
  harnessName: 'Harness',
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

final _scrollView = find.descendant(
  of: find.byType(TasksScreen),
  matching: find.byType(CustomScrollView),
);
final _prompt = find.widgetWithText(TextField, 'Prompt');
Finder _message(String text) => find.byWidgetPredicate(
  (widget) => widget is MessageContent && widget.text == text,
);

Future<ProviderContainer> _mount(
  WidgetTester tester,
  List<String> texts,
) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(800, 1100);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final client = MockClient((request) async {
    throw StateError('Layout must not request ${request.url}');
  });
  final container = ProviderContainer(
    overrides: [httpClientProvider.overrideWithValue(client)],
  );
  addTearDown(() {
    container.dispose();
    client.close();
  });
  container.read(threadProvider.notifier).state = _thread(texts);
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
  return container;
}

void _expectVisibleMessage(WidgetTester tester, String text) {
  final viewport = tester.getRect(_scrollView);
  final message = tester.getRect(_message(text));
  expect(message.top, greaterThanOrEqualTo(viewport.top));
  expect(message.bottom, lessThanOrEqualTo(viewport.bottom));
}

void _expectAtBottom(WidgetTester tester) {
  final position = tester
      .widget<CustomScrollView>(_scrollView)
      .controller!
      .position;
  expect(position.pixels, closeTo(position.maxScrollExtent, 1));
}

void main() {
  testWidgets('five saved messages run oldest to newest above the composer', (
    tester,
  ) async {
    final texts = [for (var index = 0; index < 5; index++) 'Message $index'];
    await _mount(tester, texts);

    for (var index = 0; index < texts.length; index++) {
      _expectVisibleMessage(tester, texts[index]);
      if (index > 0) {
        expect(
          tester.getBottomLeft(_message(texts[index - 1])).dy,
          lessThan(tester.getTopLeft(_message(texts[index])).dy),
        );
      }
    }
    final viewport = tester.getRect(_scrollView);
    final prompt = tester.getRect(_prompt);
    expect(prompt.top, greaterThanOrEqualTo(viewport.bottom));
    expect(prompt.bottom, lessThanOrEqualTo(1100));
  });

  testWidgets(
    'long history opens at latest and saved appends remain bottom pinned',
    (tester) async {
      final texts = [
        for (var index = 0; index < 120; index++)
          'History $index\n${List.filled(index % 5 + 1, 'Saved text').join('\n')}',
      ];
      final container = await _mount(tester, texts);
      _expectVisibleMessage(tester, texts.last);
      _expectAtBottom(tester);
      expect(find.byType(MessageContent).evaluate().length, lessThan(30));

      const appended = 'Newly saved response';
      container.read(threadProvider.notifier).state = _thread([
        ...texts,
        appended,
      ]);
      await tester.pumpAndSettle();

      _expectVisibleMessage(tester, appended);
      _expectAtBottom(tester);
      expect(
        tester.getBottomLeft(_message(texts.last)).dy,
        lessThan(tester.getTopLeft(_message(appended)).dy),
      );
    },
  );

  testWidgets('composer stays fixed and usable while reading older history', (
    tester,
  ) async {
    final texts = [for (var index = 0; index < 100; index++) 'History $index'];
    await _mount(tester, texts);
    final promptBefore = tester.getRect(_prompt);
    final controlsBefore = tester.getRect(
      find.widgetWithText(FilledButton, 'Continue'),
    );
    final controller = tester.widget<CustomScrollView>(_scrollView).controller!;
    final latestOffset = controller.offset;

    await tester.drag(_scrollView, const Offset(0, 500));
    await tester.pumpAndSettle();

    expect(controller.offset, lessThan(latestOffset));
    expect(tester.getRect(_prompt), promptBefore);
    expect(
      tester.getRect(find.widgetWithText(FilledButton, 'Continue')),
      controlsBefore,
    );
    expect(
      promptBefore.top,
      greaterThanOrEqualTo(tester.getRect(_scrollView).bottom),
    );
    expect(_prompt.hitTestable(), findsOneWidget);
    await tester.enterText(_prompt, 'Draft while reading history');
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(_prompt).controller!.text,
      'Draft while reading history',
    );
  });
}
