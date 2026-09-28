part of 'main.dart';

Future<void> startNewChat(WidgetRef ref, {Harness? harness}) async {
  if (!ref.context.mounted) return;
  if (_conversationBlocked(ref)) {
    throw const AppError(
      'Finish or save the current turn before starting a chat.',
    );
  }
  final server = ref.read(selectedServerProvider);
  if (server == null) {
    throw const AppError('Add a server in Settings to start a chat.');
  }
  bool current() =>
      ref.context.mounted &&
      identical(ref.read(selectedServerProvider), server) &&
      !_conversationBlocked(ref);
  if (harness == null) {
    final preferences = await ref.read(appPreferencesProvider.future);
    if (!current()) return;
    var catalog = ref.read(harnessesProvider);
    if (!catalog.hasError &&
        (catalog.isLoading || catalog.valueOrNull?.isEmpty != false)) {
      try {
        await ref.read(harnessesProvider.notifier).refresh();
      } catch (_) {
        // The picker exposes the shared catalog error with an inline retry.
      }
      if (!current()) return;
      catalog = ref.read(harnessesProvider);
    }
    final harnesses = catalog.valueOrNull;
    if (!catalog.hasError && !catalog.isLoading && harnesses != null) {
      if (harnesses.isEmpty) {
        throw const AppError(
          'No harnesses available. Open Settings > Harnesses.',
        );
      }
      if (harnesses.length == 1) harness = harnesses.single;
    }
    if (!ref.context.mounted) return;
    harness ??= await showModalBottomSheet<Harness>(
      context: ref.context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _NewChatHarnessPicker(
        server: server,
        rememberedId: preferences.lastHarnessIds[server.id],
        isCurrent: current,
      ),
    );
    if (!current() || harness == null) return;
  }
  if (!current()) {
    return;
  }
  await ref
      .read(appPreferencesProvider.notifier)
      .selectHarness(server.id, harness.id);
  if (!current()) {
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
  if (!current()) {
    return;
  }
  ref.read(selectedHarnessProvider.notifier).state = harness;
  ref.read(threadProvider.notifier).state = thread;
  ref.read(appDestinationProvider.notifier).state = AppDestination.chat;
}

class _NewChatHarnessPicker extends ConsumerWidget {
  const _NewChatHarnessPicker({
    required this.server,
    required this.rememberedId,
    required this.isCurrent,
  });

  final ServerConfig server;
  final String? rememberedId;
  final bool Function() isCurrent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalog = ref.watch(harnessesProvider);
    final selectedServer = ref.watch(selectedServerProvider);
    final busy = ref.watch(taskBusyProvider);
    final unsaved = ref.watch(unsavedThreadProvider);
    final managingFeed = ref.watch(feedMutationBusyProvider);
    final available =
        identical(selectedServer, server) &&
        !busy &&
        unsaved == null &&
        !managingFeed &&
        isCurrent();
    final harnesses = catalog.valueOrNull ?? const <Harness>[];
    final highlighted =
        harnesses.where((harness) => harness.id == rememberedId).firstOrNull ??
        harnesses.firstOrNull;
    final canChoose = available && !catalog.isLoading && !catalog.hasError;

    void choose(Harness harness) {
      if (!context.mounted || !isCurrent()) return;
      Navigator.pop(context, harness);
    }

    Future<void> reload() async {
      if (!context.mounted || !isCurrent()) return;
      try {
        await ref.read(harnessesProvider.notifier).refresh();
      } catch (_) {
        // HarnessesController publishes the error for the retry below.
      }
    }

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Choose a harness',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  tooltip: 'Reload harnesses',
                  onPressed: available && !catalog.isLoading ? reload : null,
                  icon: const Icon(Icons.refresh),
                ),
                IconButton(
                  tooltip: 'Cancel',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            Text(server.name),
            const SizedBox(height: 12),
            if (!available)
              const Text('The chat or server changed. Close and try again.')
            else if (catalog.isLoading)
              const LinearProgressIndicator()
            else if (catalog.hasError) ...[
              Text('${catalog.error}'),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: reload,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
              ),
            ] else if (harnesses.isEmpty)
              const Text('No harnesses available. Open Settings > Harnesses.')
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: harnesses.length,
                  itemBuilder: (context, index) {
                    final harness = harnesses[index];
                    return ListTile(
                      key: ValueKey('new-chat-harness-${harness.id}'),
                      selected: harness.id == highlighted?.id,
                      title: Text(harness.name),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Chip(label: Text(harness.baseLabel)),
                          Text('Default model: ${harness.defaultModel}'),
                        ],
                      ),
                      trailing: harness.id == highlighted?.id
                          ? const Icon(Icons.check_circle_outline)
                          : null,
                      onTap: canChoose ? () => choose(harness) : null,
                    );
                  },
                ),
              ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: canChoose && highlighted != null
                  ? () => choose(highlighted)
                  : null,
              child: const Text('Start chat'),
            ),
          ],
        ),
      ),
    );
  }
}
