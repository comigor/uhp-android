part of 'main.dart';

@immutable
class FeedTarget {
  const FeedTarget.local(ThreadSummary this.summary)
    : server = null,
      session = null;
  const FeedTarget.remote(ServerConfig this.server, ServerSession this.session)
    : summary = null;

  final ThreadSummary? summary;
  final ServerConfig? server;
  final ServerSession? session;

  String get key => isLocal
      ? 'local:${summary!.id}'
      : 'remote:${jsonEncode([server!.id, session!.id])}';
  bool get isLocal => summary != null;
  String get title => isLocal
      ? summary!.title
      : session!.title.isEmpty
      ? session!.id
      : session!.title;
  bool get archived => summary?.archived ?? false;
  bool get locked => summary?.managementLocked ?? session!.isRunning;
}

class FeedSelectionController extends StateNotifier<Map<String, FeedTarget>> {
  FeedSelectionController() : super(const {});

  void toggle(FeedTarget target) {
    if (state.containsKey(target.key)) {
      state = Map.unmodifiable({...state}..remove(target.key));
    } else if (!target.locked) {
      state = Map.unmodifiable({...state, target.key: target});
    }
  }

  void selectAll(Iterable<FeedTarget> targets) {
    state = Map.unmodifiable({
      ...state,
      for (final target in targets)
        if (!target.locked) target.key: target,
    });
  }

  void clear() => state = const {};
}

final feedSelectionProvider =
    StateNotifierProvider<FeedSelectionController, Map<String, FeedTarget>>(
      (ref) => FeedSelectionController(),
    );
final feedMutationBusyProvider = StateProvider<bool>((ref) => false);

enum FeedBatchAction { archive, unarchive, hide, delete }

String? _feedBusyReason(ProviderContainer container) {
  if (container.read(taskBusyProvider)) {
    return 'Finish the current turn before managing conversations.';
  }
  if (container.read(unsavedThreadProvider) != null) {
    return 'Save the completed turn before managing conversations.';
  }
  return null;
}

void _checkFeedBusy(ProviderContainer container) {
  final reason = _feedBusyReason(container);
  if (reason != null) throw AppError(reason);
}

bool _feedTargetLocked(ProviderContainer container, FeedTarget target) {
  if (target.locked) return true;
  final open = container.read(threadProvider);
  if (open == null || !open.managementLocked) return false;
  return target.isLocal
      ? open.id == target.summary!.id
      : open.server.id == target.server!.id &&
            open.serverSessionId == target.session!.id;
}

void _feedRefresh(ProviderContainer container) {
  container.read(feedSelectionProvider.notifier).clear();
  container.invalidate(historyProvider);
  container.read(sessionFeedRevisionProvider.notifier).state++;
}

void _feedMessage(
  ProviderContainer container,
  String message, {
  VoidCallback? undo,
}) {
  final messenger = container
      .read(appScaffoldMessengerKeyProvider)
      .currentState;
  messenger?.hideCurrentSnackBar();
  messenger?.showSnackBar(
    SnackBar(
      content: Text(message),
      action: undo == null
          ? null
          : SnackBarAction(label: 'Undo', onPressed: undo),
    ),
  );
}

class _FeedLocked implements Exception {}

class _FeedResult {
  int succeeded = 0;
  int skipped = 0;
  final errors = <String>[];
  final previousArchive = <String, bool>{};

  String message(String verb) => [
    '$verb $succeeded.',
    if (skipped > 0) 'Skipped $skipped locked or inapplicable item(s).',
    if (errors.isNotEmpty) '${errors.length} error(s): ${errors.join('; ')}',
  ].join(' ');
}

void _updateOpenFeedThread(
  ProviderContainer container,
  String id,
  bool? archived,
) {
  final open = container.read(threadProvider);
  if (open?.id != id) return;
  container.read(threadProvider.notifier).state = archived == null
      ? null
      : open!._withManagement(archived: archived);
  if (archived == null) {
    container.read(appDestinationProvider.notifier).state = AppDestination.feed;
  }
}

Future<void> _mutateLocalFeed(
  ProviderContainer container,
  String id,
  FeedBatchAction action,
  _FeedResult result,
) async {
  final store = container.read(threadStoreProvider);
  ConversationThread? before;
  final desired = action == FeedBatchAction.delete
      ? null
      : action == FeedBatchAction.archive;
  void committed() {
    result.succeeded++;
    if (desired != null && before!.archived != desired) {
      result.previousArchive[id] = before!.archived;
    }
    _updateOpenFeedThread(container, id, desired);
  }

  try {
    _checkFeedBusy(container);
    await store.mutateFeedThread(
      id,
      action,
      beforeWrite: (current) {
        _checkFeedBusy(container);
        if (current.managementLocked ||
            (container.read(threadProvider)?.id == id &&
                container.read(threadProvider)!.managementLocked)) {
          throw _FeedLocked();
        }
        before = current;
      },
    );
    committed();
  } on _FeedLocked {
    result.skipped++;
  } catch (error) {
    result.errors.add('$id: $error');
    // The file can commit before the index fails. Do not claim nothing changed
    // or lose Undo for an archived record that is already durable.
    if (before != null) {
      try {
        final actual = await store.readForManagement(id);
        if ((desired == null && actual == null) ||
            (desired != null &&
                before!.archived != desired &&
                actual?.archived == desired)) {
          committed();
        }
      } catch (inspectionError) {
        result.errors.add(
          '$id: Could not verify saved state: $inspectionError',
        );
      }
    }
  }
}

Future<void> _undoFeedBatch(
  ProviderContainer container,
  Map<String, bool> archived,
  Map<String, Map<String, String?>> hidden,
  List<FeedTarget> remoteTargets,
) async {
  final reason = _feedBusyReason(container);
  if (reason != null || container.read(feedMutationBusyProvider)) {
    _feedMessage(
      container,
      reason ?? 'Conversation management is already in progress.',
      undo: () =>
          unawaited(_undoFeedBatch(container, archived, hidden, remoteTargets)),
    );
    return;
  }
  container.read(feedMutationBusyProvider.notifier).state = true;
  final result = _FeedResult();
  final remainingArchive = {...archived};
  final remainingHidden = {
    for (final server in hidden.entries) server.key: {...server.value},
  };
  try {
    for (final entry in archived.entries) {
      final previousCount = result.succeeded;
      await _mutateLocalFeed(
        container,
        entry.key,
        entry.value ? FeedBatchAction.archive : FeedBatchAction.unarchive,
        result,
      );
      if (result.succeeded > previousCount) remainingArchive.remove(entry.key);
    }
    final patch = <String, Map<String, String?>>{};
    for (final target in remoteTargets) {
      if (!hidden.containsKey(target.server!.id) ||
          !hidden[target.server!.id]!.containsKey(target.session!.id)) {
        continue;
      }
      if (_feedTargetLocked(container, target)) {
        result.skipped++;
        continue;
      }
      patch.putIfAbsent(target.server!.id, () => {})[target.session!.id] =
          hidden[target.server!.id]![target.session!.id];
    }
    if (patch.isNotEmpty) {
      try {
        await container
            .read(appPreferencesProvider.notifier)
            .patchHiddenSessions(
              patch,
              beforeWrite: () {
                _checkFeedBusy(container);
                if (remoteTargets.any(
                  (target) =>
                      (patch[target.server!.id]?.containsKey(
                            target.session!.id,
                          ) ??
                          false) &&
                      _feedTargetLocked(container, target),
                )) {
                  throw const AppError(
                    'A session is now running. Retry Undo after it finishes.',
                  );
                }
              },
            );
        for (final server in patch.entries) {
          result.succeeded += server.value.length;
          for (final id in server.value.keys) {
            remainingHidden[server.key]!.remove(id);
          }
          if (remainingHidden[server.key]!.isEmpty) {
            remainingHidden.remove(server.key);
          }
        }
      } catch (error) {
        result.errors.add('$error');
      }
    }
    if (result.succeeded > 0) _feedRefresh(container);
  } finally {
    container.read(feedMutationBusyProvider.notifier).state = false;
  }
  _feedMessage(
    container,
    result.message('Restored'),
    undo: remainingArchive.isEmpty && remainingHidden.isEmpty
        ? null
        : () => unawaited(
            _undoFeedBatch(
              container,
              remainingArchive,
              remainingHidden,
              remoteTargets,
            ),
          ),
  );
}

Future<void> manageFeedBatch(
  WidgetRef ref,
  FeedBatchAction action,
  List<FeedTarget> targets,
) async {
  final container = ProviderScope.containerOf(ref.context, listen: false);
  final reason = _feedBusyReason(container);
  if (reason != null || container.read(feedMutationBusyProvider)) {
    _feedMessage(
      container,
      reason ?? 'Conversation management is already in progress.',
    );
    return;
  }
  final unique = {for (final target in targets) target.key: target}.values
      .toList();
  if (unique.isEmpty) return;
  final applicable = unique
      .where(
        (target) =>
            action == FeedBatchAction.hide ? !target.isLocal : target.isLocal,
      )
      .toList();
  final eligible = applicable
      .where((target) => !_feedTargetLocked(container, target))
      .toList();
  final result = _FeedResult()..skipped = applicable.length - eligible.length;
  container.read(feedMutationBusyProvider.notifier).state = true;
  Map<String, Map<String, String?>> previousHidden = {};
  try {
    if (action == FeedBatchAction.delete && eligible.isNotEmpty) {
      final confirmed = await showDialog<bool>(
        context: ref.context,
        builder: (context) => Consumer(
          builder: (context, dialogRef, _) {
            final blocked =
                dialogRef.watch(taskBusyProvider) ||
                dialogRef.watch(unsavedThreadProvider) != null;
            return AlertDialog(
              title: Text('Delete ${eligible.length} conversation(s)?'),
              content: const Text(
                'Deletes these conversations and their messages from this device only. Server sessions are never deleted. This cannot be undone.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: blocked
                      ? null
                      : () => Navigator.pop(context, true),
                  child: const Text('Delete'),
                ),
              ],
            );
          },
        ),
      );
      if (confirmed != true) return;
    }
    if (action == FeedBatchAction.hide && eligible.isNotEmpty) {
      final patch = <String, Map<String, String?>>{};
      for (final target in eligible) {
        patch.putIfAbsent(target.server!.id, () => {})[target.session!.id] =
            target.title;
      }
      try {
        previousHidden = await container
            .read(appPreferencesProvider.notifier)
            .patchHiddenSessions(
              patch,
              beforeWrite: () {
                _checkFeedBusy(container);
                if (eligible.any(
                  (target) => _feedTargetLocked(container, target),
                )) {
                  throw const AppError(
                    'A selected session is now running. Select the remaining sessions again.',
                  );
                }
              },
            );
        result.succeeded = eligible.length;
      } catch (error) {
        result.errors.add('$error');
      }
    } else {
      for (final target in eligible) {
        if (_feedTargetLocked(container, target)) {
          result.skipped++;
          continue;
        }
        await _mutateLocalFeed(container, target.summary!.id, action, result);
      }
    }
    if (result.succeeded > 0) _feedRefresh(container);
  } finally {
    container.read(feedMutationBusyProvider.notifier).state = false;
  }
  final verb = switch (action) {
    FeedBatchAction.archive => 'Archived',
    FeedBatchAction.unarchive => 'Unarchived',
    FeedBatchAction.hide => 'Hidden',
    FeedBatchAction.delete => 'Deleted',
  };
  _feedMessage(
    container,
    result.message(verb),
    undo: result.previousArchive.isEmpty && previousHidden.isEmpty
        ? null
        : () => unawaited(
            _undoFeedBatch(
              container,
              result.previousArchive,
              previousHidden,
              eligible.where((target) => !target.isLocal).toList(),
            ),
          ),
  );
}

class FeedSelectionBar extends ConsumerWidget {
  const FeedSelectionBar({super.key, required this.onSelectAll});
  final VoidCallback? onSelectAll;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final targets = ref.watch(feedSelectionProvider).values.toList();
    final localCount = targets
        .where((target) => target.isLocal && !target.locked)
        .length;
    final remoteCount = targets
        .where((target) => !target.isLocal && !target.locked)
        .length;
    final blocked =
        ref.watch(taskBusyProvider) ||
        ref.watch(unsavedThreadProvider) != null ||
        ref.watch(feedMutationBusyProvider);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Wrap(
          alignment: WrapAlignment.center,
          children: [
            TextButton(
              onPressed: blocked ? null : onSelectAll,
              child: const Text('Select all filtered'),
            ),
            if (targets.any((target) => target.isLocal))
              TextButton(
                onPressed: blocked || localCount == 0
                    ? null
                    : () => unawaited(
                        manageFeedBatch(ref, FeedBatchAction.archive, targets),
                      ),
                child: Text('Archive ($localCount)'),
              ),
            if (targets.any((target) => !target.isLocal))
              TextButton(
                onPressed: blocked || remoteCount == 0
                    ? null
                    : () => unawaited(
                        manageFeedBatch(ref, FeedBatchAction.hide, targets),
                      ),
                child: Text('Hide ($remoteCount)'),
              ),
            if (targets.any((target) => target.isLocal))
              TextButton(
                onPressed: blocked || localCount == 0
                    ? null
                    : () => unawaited(
                        manageFeedBatch(ref, FeedBatchAction.delete, targets),
                      ),
                child: Text('Delete ($localCount)'),
              ),
          ],
        ),
      ),
    );
  }
}
