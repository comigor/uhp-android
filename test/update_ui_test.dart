import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:uhp_android/update_ui.dart';
import 'package:uhp_android/updater.dart';

class _Download implements UpdateDownload {
  final completion = Completer<File>();

  @override
  Future<File> get result => completion.future;

  @override
  void cancel() => completion.completeError(const UpdateCancelled());
}

class _Updates extends UpdateService {
  _Updates()
    : super(MockClient((_) async => throw StateError('Unexpected HTTP')));

  var checks = 0;
  var downloads = 0;
  String tag = 'v99.0.0';
  final download = _Download();
  late void Function(int, int?) progress;

  @override
  Future<ReleaseInfo> check() async {
    checks++;
    return ReleaseInfo(
      tag: tag,
      name: 'Release',
      notes: List.filled(
        50,
        'Plain text release notes with **no markup**.',
      ).join('\n'),
      apk: ApkAsset(
        name: 'app.apk',
        url: Uri.https('example.test', '/app.apk'),
        size: 100,
      ),
    );
  }

  @override
  UpdateDownload startDownload(
    ReleaseInfo release, {
    required void Function(int received, int? total) onProgress,
  }) {
    downloads++;
    progress = onProgress;
    return download;
  }
}

Future<void> _mount(WidgetTester tester, _Updates updates) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        appBar: AppBar(actions: [UpdateMenu(service: updates)]),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _check(WidgetTester tester) async {
  await tester.tap(find.byTooltip('More options'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Check for updates'));
  await tester.pumpAndSettle();
}

Future<void> _download(WidgetTester tester) async {
  await tester.tap(find.text('Download & install'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  const channel = MethodChannel('dev.borges.uhp_android/updater');

  testWidgets(
    'checks only on demand and allows dismissing long release notes',
    (tester) async {
      final updates = _Updates();
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _mount(tester, updates);
      expect(updates.checks, 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(updates.checks, 0);
      await _check(tester);
      expect(find.text('Update v99.0.0'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.drag(
        find.byType(SingleChildScrollView).last,
        const Offset(0, -500),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dismiss'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(updates.downloads, 0);
    },
  );

  testWidgets('equal release shows current version without a download', (
    tester,
  ) async {
    final updates = _Updates()..tag = appVersion;
    await _mount(tester, updates);
    await _check(tester);
    expect(find.text('Up to date ($appVersion)'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(updates.downloads, 0);
  });

  testWidgets('cancelled progress never invokes the installer', (tester) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return 'launched';
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    final updates = _Updates();
    await _mount(tester, updates);
    await _check(tester);
    await _download(tester);
    updates.progress(25, 100);
    await tester.pump();
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      0.25,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(calls, isEmpty);
  });

  for (final granted in [true, false]) {
    testWidgets(
      'permission return granted=$granted resumes once without downloading again',
      (tester) async {
        final calls = <MethodCall>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async {
            calls.add(call);
            return calls.length == 1 || !granted
                ? 'permissionRequired'
                : 'launched';
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );
        final updates = _Updates();
        await _mount(tester, updates);
        await _check(tester);
        await _download(tester);
        updates.download.completion.complete(
          File('cache/updates/uhp-update-v99.0.0.apk'),
        );
        await tester.pumpAndSettle();
        expect(calls, hasLength(1));
        expect(calls.single.method, 'installApk');
        expect(calls.single.arguments['requestPermission'], isTrue);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        expect(calls, hasLength(2));
        expect(calls.last.arguments, {
          'path': 'cache/updates/uhp-update-v99.0.0.apk',
          'requestPermission': false,
        });
        expect(
          find.text(
            granted ? 'Installer opened. Confirm the update in Android.' : 'Installation not allowed. Enable "Allow from this source" and try again.',
          ),
          findsOneWidget,
        );
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        expect(calls, hasLength(2));
        expect(updates.downloads, 1);
      },
    );
  }
}
