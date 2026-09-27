part of 'main.dart';

Future<void> startNewChat(WidgetRef ref, {Harness? harness}) async {
  if (_conversationBlocked(ref)) {
    throw const AppError(
      'Finish or save the current turn before starting a chat.',
    );
  }
  final server = ref.read(selectedServerProvider);
  if (server == null) {
    throw const AppError('Add a server in Settings to start a chat.');
  }
  final preferences = await ref.read(appPreferencesProvider.future);
  if (harness == null) {
    var harnesses = ref.read(harnessesProvider).valueOrNull;
    if (harnesses == null || harnesses.isEmpty) {
      await ref.read(harnessesProvider.notifier).refresh();
      harnesses = ref.read(harnessesProvider).requireValue;
    }
    final remembered = preferences.lastHarnessIds[server.id];
    harness =
        harnesses.where((item) => item.id == remembered).firstOrNull ??
        harnesses.firstOrNull;
  }
  if (harness == null) {
    throw const AppError('No harnesses available. Open Settings > Harnesses.');
  }
  if (!ref.context.mounted ||
      !identical(ref.read(selectedServerProvider), server) ||
      _conversationBlocked(ref)) {
    return;
  }
  await ref
      .read(appPreferencesProvider.notifier)
      .selectHarness(server.id, harness.id);
  if (!ref.context.mounted ||
      !identical(ref.read(selectedServerProvider), server) ||
      _conversationBlocked(ref)) {
    return;
  }
  final now = DateTime.now().toUtc();
  final thread = ConversationThread(
    id: newLocalId(),
    title: 'New chat',
    server: server,
    harnessId: harness.id,
    harnessName: harness.name,
    createdAt: now,
    updatedAt: now,
    messages: const [],
  );
  await ref.read(threadStoreProvider).save(thread);
  if (!ref.context.mounted) return;
  ref.invalidate(historyProvider);
  if (!identical(ref.read(selectedServerProvider), server) ||
      _conversationBlocked(ref)) {
    return;
  }
  ref.read(selectedHarnessProvider.notifier).state = harness;
  ref.read(threadProvider.notifier).state = thread;
  ref.read(appDestinationProvider.notifier).state = AppDestination.chat;
}
