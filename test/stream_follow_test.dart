import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uhp_android/main.dart';

const _server = ServerConfig(
  id: 'server',
  name: 'Server',
  baseUrl: 'https://example.test',
);
final _pill = find.byKey(const ValueKey('chat-follow-live'));
final _scrollView = find.descendant(
  of: find.byType(TasksScreen),
  matching: find.byType(CustomScrollView),
);
final _composer = find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == 'Prompt',
);

ConversationThread _thread({
  String id = 'chat',
  int count = 80,
}) => ConversationThread(
  id: id,
  title: 'Conversation',
  server: _server,
  harnessId: 'harness',
  harnessName: 'Harness',
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
  messages: [
    for (var index = 0; index < count; index++)
      ThreadMessage(
        role: 'assistant',
        text: index == 0
            ? 'Oldest searchable needle'
            : 'History $index\n${List.filled(index % 5 + 2, 'Saved text').join('\n')}',
        createdAt: DateTime.utc(2026).add(Duration(seconds: index)),
      ),
  ],
);

void _stream(ProviderContainer container, int lines) {
  container.read(liveTurnProvider.notifier).state = LiveTurn(
    input: 'Current prompt',
    progress: TurnProgress(
      text: List.generate(lines, (index) => 'Live line $index').join('\n\n'),
    ),
  );
}

// Explicit frames also work while the live status indicator is animating.
Future<void> _frames(WidgetTester tester) async {
  for (var frame = 0; frame < 5; frame++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

ScrollController _controller(WidgetTester tester) =>
    tester.widget<CustomScrollView>(_scrollView).controller!;

void _expectVisibleTail(WidgetTester tester) {
  final position = _controller(tester).position;
  expect(position.pixels, closeTo(position.maxScrollExtent, 0.5));
  final card = tester.widget<ActiveTurnCard>(find.byType(ActiveTurnCard));
  final tail = find.byKey(card.tailKey!);
  final viewport = tester.getRect(_scrollView);
  final y = tester.getTopLeft(tail).dy;
  expect(y, greaterThanOrEqualTo(viewport.top));
  expect(y, lessThanOrEqualTo(viewport.bottom));
  final composer = tester.getRect(_composer);
  expect(composer.top, greaterThanOrEqualTo(viewport.bottom));
  expect(
    composer.bottom,
    lessThanOrEqualTo(
      tester.view.physicalSize.height - tester.view.viewInsets.bottom,
    ),
  );
}

Future<ProviderContainer> _mount(
  WidgetTester tester, {
  bool live = true,
  int count = 80,
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(800, 700);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final client = MockClient((request) async {
    throw StateError('Following must not request ${request.url}');
  });
  final container = ProviderContainer(
    overrides: [httpClientProvider.overrideWithValue(client)],
  );
  addTearDown(() {
    container.dispose();
    client.close();
  });
  container.read(threadProvider.notifier).state = _thread(count: count);
  if (live) _stream(container, 50);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: const Scaffold(body: TasksScreen()),
      ),
    ),
  );
  await _frames(tester);
  return container;
}

void main() {
  testWidgets(
    'initial and growing oversized live cards keep their tail visible',
    (tester) async {
      final container = await _mount(tester);
      _expectVisibleTail(tester);
      expect(_pill, findsNothing);
      var previous = _controller(tester).offset;
      expect(previous, greaterThan(0));
      for (final lines in [65, 90, 130]) {
        _stream(container, lines);
        await _frames(tester);
        expect(_controller(tester).offset, greaterThan(previous));
        _expectVisibleTail(tester);
        expect(_pill, findsNothing);
        previous = _controller(tester).offset;
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('upward history reading detaches without delta offset drift', (
    tester,
  ) async {
    final container = await _mount(tester);
    final initial = _controller(tester).offset;
    final composer = tester.getRect(_composer);
    await tester.drag(_scrollView, const Offset(0, 180));
    // Let the genuine gesture settle before measuring the reading offset.
    await tester.pump(const Duration(seconds: 1));
    await _frames(tester);
    final detached = _controller(tester).offset;
    expect(detached, lessThan(initial));
    expect(_pill, findsOneWidget);
    expect(tester.getRect(_composer), composer);
    for (final lines in [65, 85, 110]) {
      _stream(container, lines);
      await _frames(tester);
      expect(_controller(tester).offset, detached);
      expect(_pill, findsOneWidget);
      expect(tester.getRect(_composer), composer);
    }
    await tester.tap(_pill);
    await _frames(tester);
    expect(_pill, findsNothing);
    _expectVisibleTail(tester);
    final resumed = _controller(tester).offset;
    _stream(container, 145);
    await _frames(tester);
    expect(_controller(tester).offset, greaterThan(resumed));
    _expectVisibleTail(tester);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('downward motion at the latest bottom keeps following', (
    tester,
  ) async {
    final container = await _mount(tester);
    await tester.drag(_scrollView, const Offset(0, -180));
    await tester.pump(const Duration(seconds: 1));
    await _frames(tester);
    expect(_pill, findsNothing);
    _expectVisibleTail(tester);
    final beforeGrowth = _controller(tester).offset;
    _stream(container, 90);
    await _frames(tester);
    expect(_pill, findsNothing);
    expect(_controller(tester).offset, greaterThan(beforeGrowth));
    _expectVisibleTail(tester);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'pill appears only for a detached live turn and resets next turn',
    (tester) async {
      final container = await _mount(tester, live: false);
      expect(_pill, findsNothing);
      await tester.drag(_scrollView, const Offset(0, 400));
      await tester.pump(const Duration(seconds: 1));
      expect(_pill, findsNothing);
      _stream(container, 60);
      await _frames(tester);
      _expectVisibleTail(tester);
      expect(_pill, findsNothing);
      await tester.drag(_scrollView, const Offset(0, 150));
      await _frames(tester);
      expect(_pill, findsOneWidget);
      container.read(liveTurnProvider.notifier).state = null;
      await _frames(tester);
      expect(_pill, findsNothing);
      _stream(container, 70);
      await _frames(tester);
      expect(_pill, findsNothing);
      _expectVisibleTail(tester);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'keyboard metrics follow without detaching and preserve detached mode',
    (tester) async {
      final container = await _mount(tester);
      addTearDown(tester.view.resetViewInsets);
      final beforeKeyboard = tester.getSize(_scrollView).height;
      tester.view.viewInsets = const FakeViewPadding(bottom: 240);
      await _frames(tester);
      expect(_pill, findsNothing);
      _expectVisibleTail(tester);
      expect(tester.getSize(_scrollView).height, lessThan(beforeKeyboard));
      tester.view.resetViewInsets();
      await _frames(tester);
      expect(_pill, findsNothing);
      _expectVisibleTail(tester);
      await tester.drag(_scrollView, const Offset(0, 180));
      await tester.pump(const Duration(seconds: 1));
      await _frames(tester);
      expect(_pill, findsOneWidget);
      final beforeDetachedResize = _controller(tester).offset;
      tester.view.viewInsets = const FakeViewPadding(bottom: 180);
      await _frames(tester);
      final detached = _controller(tester).offset;
      expect(_pill, findsOneWidget);
      expect(detached, beforeDetachedResize);
      _stream(container, 95);
      await _frames(tester);
      expect(_controller(tester).offset, detached);
      expect(_pill, findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'turn start reaches the live row beyond a keyboard-sized viewport',
    (tester) async {
      final container = await _mount(tester, live: false, count: 1000);
      addTearDown(tester.view.resetViewInsets);
      tester.view.physicalSize = const Size(430, 900);
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      await _frames(tester);
      _stream(container, 80);
      await _frames(tester);
      _expectVisibleTail(tester);
      expect(_pill, findsNothing);
      expect(find.byType(Card).evaluate().length, lessThan(30));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'search detaches and distant lazy history re-enters the live tail',
    (tester) async {
      final container = await _mount(tester, count: 1000);
      container.read(chatSearchOpenProvider.notifier).state = true;
      await _frames(tester);
      await tester.enterText(
        find.byKey(const ValueKey('chat-search-query')),
        'searchable needle',
      );
      await _frames(tester);
      expect(
        find.textContaining('Oldest searchable needle', findRichText: true),
        findsWidgets,
      );
      expect(find.byType(ActiveTurnCard), findsNothing);
      expect(find.byType(Card).evaluate().length, lessThan(30));
      expect(_pill, findsOneWidget);
      final detached = _controller(tester).offset;
      _stream(container, 110);
      await _frames(tester);
      expect(_controller(tester).offset, detached);
      expect(find.byType(ActiveTurnCard), findsNothing);
      await tester.tap(_pill);
      await _frames(tester);
      _expectVisibleTail(tester);
      expect(_pill, findsNothing);
      expect(find.byType(Card).evaluate().length, lessThan(30));
      _stream(container, 140);
      await _frames(tester);
      _expectVisibleTail(tester);
      expect(_pill, findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'thread changes and disposal invalidate queued follow callbacks',
    (tester) async {
      final container = await _mount(tester);
      _stream(container, 120); // Queue a follow for the outgoing thread.
      container.read(liveTurnProvider.notifier).state = null;
      container.read(threadProvider.notifier).state = _thread(id: 'other');
      await _frames(tester);
      final position = _controller(tester).position;
      expect(position.pixels, closeTo(position.maxScrollExtent, 0.5));
      expect(
        find.textContaining('History 79', findRichText: true),
        findsOneWidget,
      );
      expect(_pill, findsNothing);
      expect(find.byType(ActiveTurnCard), findsNothing);
      _stream(container, 60);
      await _frames(tester);
      _expectVisibleTail(tester);
      _stream(container, 150);
      await tester.pumpWidget(const SizedBox.shrink());
      await _frames(tester);
      expect(tester.takeException(), isNull);
    },
  );
}
