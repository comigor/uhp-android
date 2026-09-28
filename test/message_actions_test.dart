import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uhp_android/main.dart';

class _Store extends ThreadStore {
  _Store() : super(() async => Directory.systemTemp);
  @override
  Future<String> readDraft(String id) async => '';
}

class _Share extends SessionFilePlatform {
  final texts = <String>[];
  @override
  Future<void> shareText(String text) async => texts.add(text);
}

void main() {
  String? copied;
  setUp(() {
    copied = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null),
  );

  Future<({ProviderContainer container, _Share platform})> mount(
    WidgetTester tester, {
    required String text,
    String role = 'assistant',
    bool linked = false,
    bool search = false,
  }) async {
    final platform = _Share();
    final container = ProviderContainer(
      overrides: [
        sessionFilePlatformProvider.overrideWithValue(platform),
        threadStoreProvider.overrideWithValue(_Store()),
      ],
    );
    addTearDown(container.dispose);
    container.read(threadProvider.notifier).state = ConversationThread(
      id: 'message-actions',
      title: 'Conversation',
      server: const ServerConfig(
        id: 'test',
        name: 'Test',
        baseUrl: 'https://example.test',
      ),
      harnessId: 'h',
      harnessName: 'Harness',
      serverSessionId: linked ? 'session' : null,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      messages: [
        ThreadMessage(
          role: role,
          text: text,
          createdAt: DateTime.utc(2026),
          attachments: role == 'user'
              ? const [
                  MessageAttachment(
                    id: 'file',
                    name: 'notes.txt',
                    bytes: 7,
                    mediaType: 'text/plain',
                  ),
                ]
              : const [],
        ),
      ],
    );
    container.read(chatSearchOpenProvider.notifier).state = search;
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
    return (container: container, platform: platform);
  }

  for (final linked in [false, true]) {
    testWidgets(
      '${linked ? 'server' : 'local'} assistant long press copies full Markdown source',
      (tester) async {
        const source = '**Bold** and next\n\nSecond paragraph with `code`.\n';
        await mount(tester, text: source, linked: linked);
        final text = find.text('Bold and next', findRichText: true);
        await tester.longPress(text);
        await tester.pumpAndSettle();
        expect(find.text('Copy full text'), findsOneWidget);
        expect(find.text('Share'), findsOneWidget);
        expect(find.text('Select text'), findsOneWidget);
        await tester.tap(find.text('Copy full text'));
        await tester.pumpAndSettle();
        expect(copied, source);
      },
    );
  }

  testWidgets(
    'raw user source shares exactly and attachment chip stays present',
    (tester) async {
      const source = '  **literal user text**\nsecond line  ';
      final fixture = await mount(tester, text: source, role: 'user');
      final text = find.text(source);
      await tester.longPress(text);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Share'));
      await tester.pumpAndSettle();
      expect(fixture.platform.texts, [source]);
      expect(find.widgetWithText(Chip, 'notes.txt'), findsOneWidget);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -200));
      await tester.pumpAndSettle();
      await tester.longPress(text);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy full text'));
      await tester.pumpAndSettle();
      expect(copied, source);
    },
  );

  testWidgets(
    'Select text returns to native partial selection instead of copying the source',
    (tester) async {
      const source = '**Bold** and next';
      await mount(tester, text: source);
      final text = find.text('Bold and next', findRichText: true);
      await tester.longPressAt(tester.getTopLeft(text) + const Offset(8, 8));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Select text'));
      await tester.pumpAndSettle();
      expect(find.text('Copy full text'), findsNothing);
      expect(find.text('Copy'), findsOneWidget);
      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();
      expect(copied, 'Bold');
    },
  );

  testWidgets('search highlights expose the same full-source actions', (
    tester,
  ) async {
    const source = '**Needle** and more';
    final fixture = await mount(tester, text: source, search: true);
    await tester.enterText(
      find.byKey(const ValueKey('chat-search-query')),
      'needle',
    );
    await tester.pumpAndSettle();
    final text = find.byWidgetPredicate(
      (widget) => widget is RichText && widget.text.toPlainText() == source,
    );
    await tester.longPress(text);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Share'));
    await tester.pumpAndSettle();
    expect(fixture.platform.texts, [source]);
  });

  testWidgets(
    'code selection and non-text card area both offer full-message actions',
    (tester) async {
      const source = '```dart\nfinal answer = 42;\n```';
      await mount(tester, text: source);
      await tester.ensureVisible(find.text('final answer = 42;\n'));
      await tester.longPress(find.text('final answer = 42;\n'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy full text'));
      await tester.pumpAndSettle();
      expect(copied, source);
      await tester.longPress(find.text('assistant'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      await tester.tap(find.text('Select text'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(SelectableText, source), findsOneWidget);
    },
  );
}
