part of 'main.dart';

void showMessage(WidgetRef ref, Object message) =>
    ref.read(snackbarControllerProvider).show(ref, '$message');

class ServersScreen extends ConsumerWidget {
  const ServersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profiles = ref.watch(serversProvider);
    final selectedId = ref.watch(selectedServerProvider.select((s) => s?.id));
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton.icon(
            icon: const Icon(Icons.add),
            label: const Text('Add server'),
            onPressed: !profiles.hasValue
                ? null
                : () async {
                    final server = ServerConfig(
                      id: newLocalId(),
                      name: 'New server',
                      baseUrl: '',
                    );
                    try {
                      await ref.read(serversProvider.notifier).add(server);
                      if (!context.mounted) return;
                      await Navigator.of(context).push<void>(
                        MaterialPageRoute(
                          builder: (_) => ServerEditor(server: server),
                        ),
                      );
                    } catch (error) {
                      if (context.mounted) showMessage(ref, error);
                    }
                  },
          ),
        ),
        TextButton(
          onPressed: !profiles.hasValue
              ? null
              : () async {
                  final server = ServerConfig(
                    id: newLocalId(),
                    name: demoServer.name,
                    baseUrl: demoServer.baseUrl,
                  );
                  try {
                    await ref.read(serversProvider.notifier).add(server);
                    if (context.mounted) {
                      await Navigator.of(context).push<void>(
                        MaterialPageRoute(
                          builder: (_) => ServerEditor(server: server),
                        ),
                      );
                    }
                  } catch (error) {
                    if (context.mounted) showMessage(ref, error);
                  }
                },
          child: const Text('Add demo profile'),
        ),
        Expanded(
          child: profiles.when(
            loading: () => const Center(child: Text('Loading profiles…')),
            error: (error, _) =>
                Center(child: Text('Cannot load profiles: $error')),
            data: (servers) => servers.isEmpty
                ? const Center(
                    child: Text('No saved servers. Add one to begin.'),
                  )
                : ListView.builder(
                    itemCount: servers.length,
                    itemBuilder: (context, index) {
                      final server = servers[index];
                      return ListTile(
                        leading: Icon(
                          server.id == selectedId
                              ? Icons.check_circle
                              : Icons.dns_outlined,
                        ),
                        title: Text(
                          server.name.isEmpty ? 'Unnamed server' : server.name,
                        ),
                        subtitle: Text(
                          '${server.baseUrl}\n${server.hasApiKey ? server.testResult ?? 'Not tested' : 'API key required'}',
                        ),
                        isThreeLine: true,
                        onTap: () {
                          if (!server.hasApiKey) {
                            Navigator.of(context).push<void>(
                              MaterialPageRoute(
                                builder: (_) => ServerEditor(server: server),
                              ),
                            );
                            return;
                          }
                          ref.read(selectedServerProvider.notifier).state =
                              server;
                          ref.read(selectedHarnessProvider.notifier).state =
                              null;
                          ref.invalidate(harnessesProvider);
                        },
                        trailing: IconButton(
                          tooltip: 'Edit server',
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: () => Navigator.of(context).push<void>(
                            MaterialPageRoute(
                              builder: (_) => ServerEditor(server: server),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}

class ServerEditor extends ConsumerStatefulWidget {
  const ServerEditor({super.key, required this.server});
  final ServerConfig server;
  @override
  ConsumerState<ServerEditor> createState() => _ServerEditorState();
}

class _ServerEditorState extends ConsumerState<ServerEditor> {
  late ServerConfig _draft = widget.server;
  late final _name = TextEditingController(text: _draft.name);
  late final _url = TextEditingController(text: _draft.baseUrl);
  late final _tokenId = TextEditingController(text: _draft.accessTokenId);
  late final _token = TextEditingController(text: _draft.accessToken);
  late final _apiKey = TextEditingController(text: _draft.apiKey);
  Future<void> _saved = Future<void>.value();
  bool _testing = false;
  String? _saveError;

  @override
  void dispose() {
    for (final c in [_name, _url, _tokenId, _token, _apiKey]) {
      c.dispose();
    }
    super.dispose();
  }

  void _changed() {
    setState(() {
      _draft = ServerConfig(
        id: _draft.id,
        name: _name.text,
        baseUrl: normalizeBaseUrl(_url.text),
        apiKey: _apiKey.text,
        accessTokenId: _tokenId.text,
        accessToken: _token.text,
      );
    });
    // Queue every mutation, without debounce timers. No manual save step.
    _persist();
  }

  void _persist() {
    final operation = ref.read(serversProvider.notifier).updateProfile(_draft);
    _saved = operation;
    unawaited(
      operation.then(
        (_) {
          if (mounted) setState(() => _saveError = null);
        },
        onError: (Object error, StackTrace _) {
          if (mounted) {
            setState(() => _saveError = '$error');
            showMessage(ref, error);
          }
        },
      ),
    );
  }

  Future<void> _test() async {
    final service = ref.read(uhpServiceProvider);
    final profiles = ref.read(serversProvider.notifier);
    setState(() => _testing = true);
    try {
      await _saved;
      final result = await service.testConnection(_draft);
      await profiles.setTestResult(_draft.id, result);
      _draft = _draft.copyWith(testResult: result);
      if (mounted) showMessage(ref, result);
    } catch (error) {
      _draft = _draft.copyWith(testResult: '$error');
      try {
        await profiles.setTestResult(_draft.id, '$error');
      } catch (storageError) {
        if (mounted) showMessage(ref, storageError);
      }
      if (mounted) showMessage(ref, error);
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Server profile'),
      actions: [
        IconButton(
          tooltip: 'Delete server',
          icon: const Icon(Icons.delete_outline),
          onPressed: _testing
              ? null
              : () async {
                  try {
                    await ref.read(serversProvider.notifier).delete(_draft.id);
                    if (context.mounted) Navigator.of(context).pop();
                  } catch (error) {
                    if (mounted) showMessage(ref, error);
                  }
                },
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('Changes are saved automatically on this device.'),
        if (_saveError != null) ...[
          Text('Not saved: $_saveError'),
          TextButton(
            onPressed: _persist,
            child: const Text('Retry storage write'),
          ),
        ],
        TextField(
          controller: _name,
          enabled: !_testing,
          onChanged: (_) => _changed(),
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        TextField(
          controller: _url,
          enabled: !_testing,
          onChanged: (_) => _changed(),
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(labelText: 'Base URL'),
        ),
        TextField(
          controller: _apiKey,
          enabled: !_testing,
          onChanged: (_) => _changed(),
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: 'API key (required)',
            helperText: 'Create an API key in server Settings → Keys.',
            errorText: _draft.hasApiKey ? null : 'API key required',
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Pangolin edge authentication (optional)',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const Text('Only needed behind Pangolin; fill both token fields.'),
        TextField(
          controller: _tokenId,
          enabled: !_testing,
          onChanged: (_) => _changed(),
          decoration: const InputDecoration(labelText: 'P-Access-Token-Id'),
        ),
        TextField(
          controller: _token,
          enabled: !_testing,
          onChanged: (_) => _changed(),
          obscureText: true,
          decoration: const InputDecoration(labelText: 'P-Access-Token'),
        ),
        const SizedBox(height: 16),
        OutlinedButton(
          onPressed: _testing ? null : _test,
          child: Text(_testing ? 'Testing…' : 'Test connection'),
        ),
        if (_draft.testResult != null) Text(_draft.testResult!),
      ],
    ),
  );
}

class HarnessesScreen extends ConsumerWidget {
  const HarnessesScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final harnesses = ref.watch(harnessesProvider);
    final blocked =
        ref.watch(taskBusyProvider) || ref.watch(unsavedThreadProvider) != null;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton(
            onPressed: harnesses.isLoading
                ? null
                : () async {
                    try {
                      await ref.read(harnessesProvider.notifier).refresh();
                    } catch (error) {
                      if (context.mounted) showMessage(ref, error);
                    }
                  },
            child: const Text('Load harnesses'),
          ),
        ),
        Expanded(
          child: harnesses.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => Center(child: Text('$error')),
            data: (items) => items.isEmpty
                ? const Center(child: Text('No harnesses loaded.'))
                : ListView.builder(
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final harness = items[index];
                      return ListTile(
                        title: Text(harness.name),
                        subtitle: Text(
                          '${harness.baseLabel}\n${harness.defaultModel}',
                        ),
                        isThreeLine: true,
                        trailing: IconButton(
                          tooltip: 'Edit default model',
                          icon: const Icon(Icons.tune),
                          onPressed: blocked
                              ? null
                              : () {
                                  final server = ref.read(
                                    selectedServerProvider,
                                  );
                                  if (server == null) return;
                                  showDialog<void>(
                                    context: context,
                                    builder: (_) => _HarnessModelEditor(
                                      server: server,
                                      harness: harness,
                                    ),
                                  );
                                },
                        ),
                        onTap: blocked
                            ? null
                            : () {
                                ref
                                        .read(selectedHarnessProvider.notifier)
                                        .state =
                                    harness;
                                ref.read(threadProvider.notifier).state = null;
                                ref.read(selectedTabProvider.notifier).state =
                                    AppTab.tasks;
                              },
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}

class TasksScreen extends ConsumerStatefulWidget {
  const TasksScreen({super.key});
  @override
  ConsumerState<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends ConsumerState<TasksScreen> {
  final _prompt = TextEditingController();
  String? _model;
  Object? _modelScope;
  bool _refreshing = false;

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  Future<void> _refreshSession(ConversationThread thread) async {
    if (_refreshing ||
        thread.hasServerContinuing ||
        _conversationBlocked(ref)) {
      return;
    }
    setState(() => _refreshing = true);
    bool current() => mounted && identical(ref.read(threadProvider), thread);
    try {
      final servers = await ref.read(serversProvider.future);
      if (!current() || _conversationBlocked(ref)) return;
      ServerConfig? server;
      for (final candidate in servers) {
        if (candidate.id == thread.server.id &&
            normalizeBaseUrl(candidate.baseUrl) ==
                normalizeBaseUrl(thread.server.baseUrl)) {
          server = candidate;
          break;
        }
      }
      if (server == null) {
        throw const AppError(
          'The saved server profile was deleted or changed. This thread is read-only.',
        );
      }
      await _openServerSession(
        ref,
        server,
        thread.serverSessionId!,
        harnessName: thread.harnessName,
        isCurrent: current,
      );
    } catch (error) {
      if (mounted) showMessage(ref, error);
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _chooseModel(
    ServerConfig server,
    String harnessId,
    Object scope,
  ) async {
    final selection = await showDialog<_ModelSelection>(
      context: context,
      builder: (_) => _ModelPicker(
        service: ref.read(uhpServiceProvider),
        server: server,
        harnessId: harnessId,
        selected: _model,
      ),
    );
    if (!mounted ||
        _modelScope != scope ||
        _conversationBlocked(ref) ||
        (ref.read(threadProvider)?.hasServerContinuing ?? false) ||
        selection == null) {
      return;
    }
    setState(() => _model = selection.model);
  }

  @override
  Widget build(BuildContext context) {
    final thread = ref.watch(threadProvider);
    final harness = ref.watch(selectedHarnessProvider);
    final server = thread?.server ?? ref.watch(selectedServerProvider);
    final harnessId = thread?.harnessId ?? harness?.id;
    final scope = (
      thread?.id,
      server?.id,
      server == null ? null : normalizeBaseUrl(server.baseUrl),
      harnessId,
    );
    if (_modelScope != scope) {
      _modelScope = scope;
      _model = null;
    }
    final busy = ref.watch(taskBusyProvider);
    final unsaved = ref.watch(unsavedThreadProvider) != null;
    final running =
        thread?.serverSessionId != null &&
        const {
          'running',
          'in_progress',
        }.contains(thread?.serverSessionStatus?.toLowerCase());
    final continuing = thread?.hasServerContinuing ?? false;
    final blocked = busy || unsaved || running || continuing || _refreshing;
    final hasLiveTurn = ref.watch(
      liveTurnProvider.select((turn) => turn != null),
    );
    final messages = thread?.messages ?? const <ThreadMessage>[];
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Text(
                  thread == null
                      ? 'Harness: ${harness?.name ?? 'none'}'
                      : '${thread.title} · ${thread.harnessName}',
                ),
                if (thread?.model != null && thread!.model!.isNotEmpty)
                  Text('Session model: ${thread.model}'),
                if (thread?.serverSessionId != null) ...[
                  _SessionStatus(status: thread!.serverSessionStatus ?? ''),
                  if (running && !continuing)
                    const Text(
                      'This session is running on the server. Refresh when it finishes to continue.',
                    ),
                  TextButton.icon(
                    icon: const Icon(Icons.refresh),
                    label: Text(
                      _refreshing ? 'Refreshing…' : 'Refresh server session',
                    ),
                    onPressed: busy || unsaved || continuing || _refreshing
                        ? null
                        : () => _refreshSession(thread),
                  ),
                ],
                if (continuing) ...[
                  const Text('Waiting for previous turn to finish on server'),
                  TextButton.icon(
                    icon: const Icon(Icons.refresh),
                    label: const Text('Check now'),
                    onPressed: () async {
                      try {
                        await ref.read(serverContinuationProvider).checkNow();
                      } catch (error) {
                        if (mounted) showMessage(ref, error);
                      }
                    },
                  ),
                ],
                ActionChip(
                  avatar: const Icon(Icons.tune),
                  label: Text('Model: ${_model ?? 'Harness default'}'),
                  onPressed: blocked || server == null || harnessId == null
                      ? null
                      : () => _chooseModel(server, harnessId, scope),
                ),
                TextField(
                  controller: _prompt,
                  minLines: 1,
                  maxLines: 3,
                  decoration: const InputDecoration(labelText: 'Prompt'),
                  enabled: !blocked,
                ),
                Wrap(
                  spacing: 12,
                  children: [
                    FilledButton(
                      onPressed: blocked
                          ? null
                          : () async {
                              final runner = ref.read(taskRunnerProvider);
                              final messenger = ref.read(
                                appScaffoldMessengerKeyProvider,
                              );
                              try {
                                await runner.submit(
                                  _prompt.text,
                                  model: _model,
                                );
                                if (mounted) _prompt.clear();
                              } catch (error) {
                                messenger.currentState?.showSnackBar(
                                  SnackBar(content: Text('$error')),
                                );
                              }
                            },
                      child: Text(
                        busy
                            ? 'Working…'
                            : thread == null
                            ? 'Run task'
                            : 'Continue',
                      ),
                    ),
                    if (busy) const StopTurnButton(),
                    TextButton(
                      onPressed: busy || unsaved || _refreshing
                          ? null
                          : () {
                              ref.read(threadProvider.notifier).state = null;
                              setState(() => _model = null);
                            },
                      child: const Text('New task'),
                    ),
                  ],
                ),
                if (unsaved) ...[
                  const Text(
                    'Completed turn not yet saved. Retry before leaving this conversation.',
                  ),
                  TextButton(
                    onPressed: busy
                        ? null
                        : () async {
                            try {
                              await ref.read(taskRunnerProvider).savePending();
                            } catch (error) {
                              if (mounted) showMessage(ref, error);
                            }
                          },
                    child: const Text('Retry storage write'),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (messages.isEmpty && !hasLiveTurn)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: Text('No task history yet.')),
          )
        else
          SliverList.builder(
            itemCount: messages.length + (hasLiveTurn ? 1 : 0),
            itemBuilder: (context, index) {
              if (hasLiveTurn && index == 0) return const ActiveTurnCard();
              final message =
                  messages[messages.length - 1 - index + (hasLiveTurn ? 1 : 0)];
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        message.role,
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                      SelectableText(message.text),
                      if (message.role == 'assistant')
                        if (message.status == TurnStatus.serverContinuing)
                          const Chip(
                            visualDensity: VisualDensity.compact,
                            label: Text('Server still working…'),
                          )
                        else
                          Text(message.status.name),
                      if (message.error != null)
                        Text(
                          message.error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      if (message.responseId != null)
                        Text(
                          'response_id=${message.responseId}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      if (message.usage != null)
                        UsageText(usage: message.usage!),
                    ],
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}

class ActiveTurnCard extends ConsumerWidget {
  const ActiveTurnCard({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final turn = ref.watch(liveTurnProvider);
    if (turn == null) return const SizedBox.shrink();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('user', style: Theme.of(context).textTheme.labelLarge),
            Text(turn.input),
            const Divider(),
            Text(turn.stopping ? 'Stopping…' : 'assistant · running'),
            SelectableText(turn.progress.text),
            for (final tool in turn.progress.tools) Text('tool: $tool'),
          ],
        ),
      ),
    );
  }
}

class StopTurnButton extends ConsumerWidget {
  const StopTurnButton({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stopping = ref.watch(
      liveTurnProvider.select((turn) => turn == null || turn.stopping),
    );
    return OutlinedButton.icon(
      icon: const Icon(Icons.stop),
      label: Text(stopping ? 'Stopping…' : 'Stop'),
      onPressed: stopping
          ? null
          : () async {
              final messenger = ref.read(appScaffoldMessengerKeyProvider);
              try {
                await ref.read(taskRunnerProvider).cancel();
              } catch (error) {
                messenger.currentState?.showSnackBar(
                  SnackBar(content: Text('$error')),
                );
              }
            },
    );
  }
}

class UsageText extends StatelessWidget {
  const UsageText({super.key, required this.usage});
  final TokenUsage usage;
  @override
  Widget build(BuildContext context) => Text(
    '${[if (usage.inputTokens != null) 'input: ${usage.inputTokens}', if (usage.outputTokens != null) 'output: ${usage.outputTokens}', if (usage.totalTokens != null) 'total: ${usage.totalTokens}'].join(' · ')} tokens',
    style: Theme.of(context).textTheme.bodySmall,
  );
}

String relativeTime(DateTime date) {
  final age = DateTime.now().difference(date);
  if (age.inMinutes < 1) return 'just now';
  if (age.inHours < 1) return '${age.inMinutes}m ago';
  if (age.inDays < 1) return '${age.inHours}h ago';
  return '${age.inDays}d ago';
}

class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(historyProvider);
    final blocked =
        ref.watch(taskBusyProvider) || ref.watch(unsavedThreadProvider) != null;
    return history.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => Center(child: Text('Cannot load history: $error')),
      data: (threads) => threads.isEmpty
          ? const Center(child: Text('No saved conversations.'))
          : ListView.builder(
              itemCount: threads.length,
              itemBuilder: (context, index) {
                final summary = threads[index];
                return ListTile(
                  title: Text(summary.title),
                  subtitle: Text(
                    '${summary.harnessName} · ${relativeTime(summary.updatedAt)}',
                  ),
                  onTap: blocked
                      ? null
                      : () async {
                          try {
                            final thread = await ref
                                .read(threadStoreProvider)
                                .read(summary.id);
                            if (!context.mounted) return;
                            if (thread == null) {
                              throw const AppError(
                                'This conversation is missing or malformed.',
                              );
                            }
                            final servers = await ref.read(
                              serversProvider.future,
                            );
                            if (!context.mounted) return;
                            if (ref.read(taskBusyProvider) ||
                                ref.read(unsavedThreadProvider) != null) {
                              return;
                            }
                            ref.read(threadProvider.notifier).state = thread;
                            ref.read(selectedTabProvider.notifier).state =
                                AppTab.tasks;
                            if (!servers.any((s) => s.id == thread.server.id)) {
                              showMessage(
                                ref,
                                'The saved server profile was deleted. You can read this thread, but cannot continue.',
                              );
                            }
                          } catch (error) {
                            if (context.mounted) showMessage(ref, error);
                          }
                        },
                  onLongPress: blocked
                      ? null
                      : () async {
                          final confirmed = await showDialog<bool>(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: const Text('Delete conversation?'),
                              content: Text(summary.title),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.pop(context, false),
                                  child: const Text('Cancel'),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.pop(context, true),
                                  child: const Text('Delete'),
                                ),
                              ],
                            ),
                          );
                          if (confirmed != true || !context.mounted) return;
                          try {
                            await ref
                                .read(threadStoreProvider)
                                .delete(summary.id);
                            if (!context.mounted) return;
                            if (ref.read(threadProvider)?.id == summary.id) {
                              ref.read(threadProvider.notifier).state = null;
                            }
                            ref.invalidate(historyProvider);
                          } catch (error) {
                            if (context.mounted) showMessage(ref, error);
                          }
                        },
                  trailing: const Icon(Icons.chevron_right),
                );
              },
            ),
    );
  }
}
