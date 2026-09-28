part of 'main.dart';

String? _threadManagementReason(
  bool busy,
  ConversationThread? unsaved,
  ConversationThread thread,
) {
  if (busy) return 'Finish the current turn before managing conversations.';
  if (unsaved != null) {
    return 'Save the completed turn before managing conversations.';
  }
  if (thread.hasServerContinuing ||
      const {
        'running',
        'in_progress',
      }.contains(thread.serverSessionStatus?.toLowerCase())) {
    return 'Wait for this turn to finish before managing this conversation.';
  }
  return null;
}

class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key});

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  bool _showArchived = false;

  Future<void> _open(ThreadSummary summary) async {
    if (_conversationBlocked(ref)) return;
    try {
      final thread = await ref.read(threadStoreProvider).read(summary.id);
      if (!mounted) return;
      if (thread == null) {
        throw const AppError('This conversation is missing or malformed.');
      }
      final servers = await ref.read(serversProvider.future);
      if (!mounted || _conversationBlocked(ref)) return;
      await ref
          .read(appPreferencesProvider.notifier)
          .selectHarness(thread.server.id, thread.harnessId);
      if (!mounted || _conversationBlocked(ref)) return;
      ref.read(threadProvider.notifier).state = thread;
      ref.read(appDestinationProvider.notifier).state = AppDestination.chat;
      if (!servers.any((server) => server.id == thread.server.id)) {
        showMessage(
          ref,
          'The saved server profile was deleted. You can read this thread, but cannot continue.',
        );
      }
    } catch (error) {
      if (mounted) showMessage(ref, error);
    }
  }

  Future<void> _manage(ThreadSummary summary) async {
    try {
      final thread = await ref.read(threadStoreProvider).read(summary.id);
      if (!mounted) return;
      if (thread == null) {
        throw const AppError('This conversation is missing or malformed.');
      }
      await showModalBottomSheet<void>(
        context: context,
        enableDrag: false,
        builder: (_) => _ThreadActions(thread: thread),
      );
    } catch (error) {
      if (mounted) showMessage(ref, error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final history = ref.watch(historyProvider);
    final blocked =
        ref.watch(taskBusyProvider) ||
        ref.watch(unsavedThreadProvider) != null ||
        ref.watch(feedMutationBusyProvider);
    final selection = ref.watch(feedSelectionProvider);
    final selecting = selection.isNotEmpty;
    final query = ref.watch(feedSearchQueryProvider);
    return history.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => Center(child: Text('Cannot load history: $error')),
      data: (threads) {
        final visible = threads
            .where(
              (thread) =>
                  (_showArchived || !thread.archived) &&
                  matchesFeedSearch(query, thread.title, thread.firstUserLine),
            )
            .toList();
        final rowCount = visible.isEmpty ? 1 : visible.length;
        return Column(
          children: [
            if (selecting)
              FeedSelectionBar(
                onSelectAll: blocked
                    ? null
                    : () => ref
                          .read(feedSelectionProvider.notifier)
                          .selectAll(visible.map(FeedTarget.local)),
              ),
            Expanded(
              child: ListView.builder(
                itemCount: rowCount + 1,
                itemBuilder: (context, index) {
                  if (index == rowCount) {
                    return SwitchListTile(
                      title: const Text('Show archived'),
                      value: _showArchived,
                      onChanged: (value) =>
                          setState(() => _showArchived = value),
                    );
                  }
                  if (visible.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        query.isEmpty
                            ? 'No saved conversations.'
                            : 'No matching saved conversations.',
                      ),
                    );
                  }
                  final summary = visible[index];
                  final target = FeedTarget.local(summary);
                  final locked = blocked || target.locked;
                  void toggle() {
                    if (!_conversationBlocked(ref) && !target.locked) {
                      ref.read(feedSelectionProvider.notifier).toggle(target);
                    }
                  }

                  return Dismissible(
                    key: ValueKey('swipe-${target.key}'),
                    direction: selecting || locked
                        ? DismissDirection.none
                        : summary.archived
                        ? DismissDirection.endToStart
                        : DismissDirection.startToEnd,
                    background: Container(
                      color: Theme.of(context).colorScheme.secondaryContainer,
                      alignment: summary.archived
                          ? AlignmentDirectional.centerEnd
                          : AlignmentDirectional.centerStart,
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Icon(
                        summary.archived
                            ? Icons.unarchive_outlined
                            : Icons.archive_outlined,
                      ),
                    ),
                    confirmDismiss: (_) async {
                      if (_conversationBlocked(ref) ||
                          ref.read(feedSelectionProvider).isNotEmpty ||
                          target.locked) {
                        return false;
                      }
                      await manageFeedBatch(
                        ref,
                        summary.archived
                            ? FeedBatchAction.unarchive
                            : FeedBatchAction.archive,
                        [target],
                      );
                      return false;
                    },
                    child: Opacity(
                      opacity: summary.archived ? 0.55 : 1,
                      child: ListTile(
                        key: ValueKey('thread-${summary.id}'),
                        enabled: !blocked,
                        selected: selection.containsKey(target.key),
                        leading: selecting
                            ? Checkbox(
                                value: selection.containsKey(target.key),
                                onChanged: locked ? null : (_) => toggle(),
                              )
                            : null,
                        title: Text(summary.title),
                        subtitle: Text(
                          '${summary.archived ? 'Archived · ' : ''}${summary.harnessName} · ${relativeTime(summary.updatedAt)}',
                        ),
                        trailing: selecting
                            ? null
                            : IconButton(
                                key: ValueKey('thread-actions-${summary.id}'),
                                tooltip: 'Conversation options',
                                icon: const Icon(Icons.more_vert),
                                onPressed: locked
                                    ? null
                                    : () => _manage(summary),
                              ),
                        onLongPress: locked ? null : toggle,
                        onTap: blocked
                            ? null
                            : selecting
                            ? (target.locked ? null : toggle)
                            : () => _open(summary),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

enum _ThreadAction { rename, archive, delete }

class _ThreadActions extends ConsumerStatefulWidget {
  const _ThreadActions({required this.thread});
  final ConversationThread thread;

  @override
  ConsumerState<_ThreadActions> createState() => _ThreadActionsState();
}

class _ThreadActionsState extends ConsumerState<_ThreadActions> {
  bool _saving = false;

  String? _reason(ConversationThread thread) => _threadManagementReason(
    ref.read(taskBusyProvider),
    ref.read(unsavedThreadProvider),
    thread,
  );

  Future<void> _run(_ThreadAction action) async {
    if (_saving || _reason(widget.thread) != null) return;
    String? title;
    if (action == _ThreadAction.rename) {
      title = await showDialog<String>(
        context: context,
        builder: (_) => _RenameThreadDialog(thread: widget.thread),
      );
      if (title == null || !mounted) return;
    } else if (action == _ThreadAction.delete) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => Consumer(
          builder: (context, ref, _) {
            final reason = _threadManagementReason(
              ref.watch(taskBusyProvider),
              ref.watch(unsavedThreadProvider),
              widget.thread,
            );
            return AlertDialog(
              title: const Text('Delete conversation?'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(widget.thread.title),
                  const SizedBox(height: 12),
                  const Text(
                    'Deletes this conversation and its messages from this device only. Server sessions are never deleted.',
                  ),
                  if (reason != null) Text(reason),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: reason == null
                      ? () => Navigator.pop(context, true)
                      : null,
                  child: const Text('Delete'),
                ),
              ],
            );
          },
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    setState(() => _saving = true);
    try {
      final store = ref.read(threadStoreProvider);
      final current = await store.read(widget.thread.id);
      if (!mounted) return;
      if (current == null) {
        throw const AppError('This conversation no longer exists.');
      }
      final reason = _reason(current);
      if (reason != null) throw AppError(reason);
      ConversationThread? updated;
      switch (action) {
        case _ThreadAction.rename:
          updated = await store.rename(current.id, title!);
        case _ThreadAction.archive:
          updated = await store.setArchived(current.id, !current.archived);
        case _ThreadAction.delete:
          await store.delete(current.id);
      }
      if (!mounted) return;
      if (action != _ThreadAction.delete && updated == null) {
        throw const AppError('This conversation no longer exists.');
      }
      if (ref.read(threadProvider)?.id == current.id) {
        ref.read(threadProvider.notifier).state = updated;
        if (action == _ThreadAction.delete) {
          ref.read(appDestinationProvider.notifier).state = AppDestination.feed;
        }
      }
      ref.invalidate(historyProvider);
      // Release PopScope before closing the sheet after the durable write.
      setState(() => _saving = false);
      Navigator.pop(context);
    } catch (error) {
      if (mounted) showMessage(ref, error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final open = ref.watch(threadProvider);
    final thread = open?.id == widget.thread.id ? open! : widget.thread;
    final reason = _threadManagementReason(
      ref.watch(taskBusyProvider),
      ref.watch(unsavedThreadProvider),
      thread,
    );
    final enabled = !_saving && reason == null;
    return PopScope(
      canPop: !_saving,
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                thread.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (reason != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(reason),
              ),
            if (_saving) const LinearProgressIndicator(),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Rename'),
              enabled: enabled,
              onTap: enabled ? () => _run(_ThreadAction.rename) : null,
            ),
            ListTile(
              leading: Icon(
                thread.archived
                    ? Icons.unarchive_outlined
                    : Icons.archive_outlined,
              ),
              title: Text(thread.archived ? 'Unarchive' : 'Archive'),
              enabled: enabled,
              onTap: enabled ? () => _run(_ThreadAction.archive) : null,
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete'),
              enabled: enabled,
              onTap: enabled ? () => _run(_ThreadAction.delete) : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _RenameThreadDialog extends ConsumerStatefulWidget {
  const _RenameThreadDialog({required this.thread});
  final ConversationThread thread;
  @override
  ConsumerState<_RenameThreadDialog> createState() =>
      _RenameThreadDialogState();
}

class _RenameThreadDialogState extends ConsumerState<_RenameThreadDialog> {
  late final _title = TextEditingController(text: widget.thread.title);
  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reason = _threadManagementReason(
      ref.watch(taskBusyProvider),
      ref.watch(unsavedThreadProvider),
      widget.thread,
    );
    final allowed = reason == null && _title.text.trim().isNotEmpty;
    return AlertDialog(
      title: const Text('Rename conversation'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _title,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Title'),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) {
              if (allowed) Navigator.pop(context, _title.text.trim());
            },
          ),
          if (reason != null) Text(reason),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: allowed
              ? () => Navigator.pop(context, _title.text.trim())
              : null,
          child: const Text('Rename'),
        ),
      ],
    );
  }
}
