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
                      authMode: AuthMode.pangolin,
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
                          '${server.baseUrl}\n${server.testResult ?? 'Not tested'}',
                        ),
                        isThreeLine: true,
                        onTap: () {
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
  late final _username = TextEditingController(text: _draft.username);
  late final _password = TextEditingController(text: _draft.password);
  Future<void> _saved = Future<void>.value();
  bool _testing = false;
  String? _saveError;

  @override
  void dispose() {
    for (final c in [_name, _url, _tokenId, _token, _username, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  void _changed({AuthMode? mode}) {
    _draft = ServerConfig(
      id: _draft.id,
      name: _name.text,
      baseUrl: normalizeBaseUrl(_url.text),
      authMode: mode ?? _draft.authMode,
      accessTokenId: _tokenId.text,
      accessToken: _token.text,
      username: _username.text,
      password: _password.text,
    );
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
      final authenticated = await service.login(_draft);
      if (authenticated.cookie != _draft.cookie) {
        await profiles.updateCookie(_draft, authenticated.cookie!);
      }
      final result = await service.testConnection(authenticated);
      await profiles.setTestResult(
        _draft.id,
        result,
        cookie: authenticated.cookie,
      );
      _draft = authenticated.copyWith(testResult: result);
      if (mounted) showMessage(ref, result);
    } catch (error) {
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
        DropdownButtonFormField<AuthMode>(
          isExpanded: true,
          initialValue: _draft.authMode,
          decoration: const InputDecoration(labelText: 'Auth mode'),
          items: const [
            DropdownMenuItem(
              value: AuthMode.pangolin,
              child: Text(
                'Pangolin machine token',
                overflow: TextOverflow.ellipsis,
              ),
            ),
            DropdownMenuItem(
              value: AuthMode.console,
              child: Text('Console login cookie'),
            ),
          ],
          onChanged: _testing
              ? null
              : (mode) {
                  setState(() => _changed(mode: mode));
                },
        ),
        if (_draft.authMode == AuthMode.pangolin) ...[
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
        ] else ...[
          TextField(
            controller: _username,
            enabled: !_testing,
            onChanged: (_) => _changed(),
            decoration: const InputDecoration(labelText: 'Username'),
          ),
          TextField(
            controller: _password,
            enabled: !_testing,
            onChanged: (_) => _changed(),
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Password'),
          ),
        ],
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

final unsavedThreadProvider = StateProvider<ConversationThread?>((ref) => null);
final taskRunnerProvider = Provider<TaskRunner>(TaskRunner.new);

class TaskRunner {
  TaskRunner(this.ref);
  final Ref ref;

  Future<void> submit(String input) async {
    if (ref.read(taskBusyProvider)) return;
    if (ref.read(unsavedThreadProvider) != null) {
      throw const AppError('Save the completed turn before continuing.');
    }
    if (input.trim().isEmpty) throw const AppError('Enter a prompt first.');
    final thread = ref.read(threadProvider);
    final server = thread?.server ?? ref.read(selectedServerProvider);
    final harness = thread == null
        ? ref.read(selectedHarnessProvider)
        : Harness(
            id: thread.harnessId,
            name: thread.harnessName,
            baseLabel: '',
            defaultModel: thread.model ?? '',
          );
    if (server == null || harness == null) {
      throw const AppError('Select a server and harness first.');
    }
    ref.read(taskBusyProvider.notifier).state = true;
    try {
      final servers = await ref.read(serversProvider.future);
      if (!servers.any((s) => s.id == server.id)) {
        throw const AppError(
          'The saved server profile was deleted. This thread cannot continue.',
        );
      }
      if (thread != null && (thread.lastResponseId?.isEmpty ?? true)) {
        throw const AppError(
          'This thread has no last assistant response ID to continue.',
        );
      }
      final service = ref.read(uhpServiceProvider);
      final authenticated =
          server.authMode == AuthMode.console &&
              (server.cookie?.isEmpty ?? true)
          ? await service.login(server)
          : server;
      if (authenticated.cookie != server.cookie) {
        await ref
            .read(serversProvider.notifier)
            .updateCookie(server, authenticated.cookie!);
      }
      final record = await service.createResponse(
        authenticated,
        ResponseDraft(
          input: input.trim(),
          harnessId: harness.id,
          previousResponseId: thread?.lastResponseId,
        ),
      );
      final updated = thread == null
          ? ConversationThread.start(
              server: authenticated,
              harness: harness,
              prompt: input.trim(),
              record: record,
            )
          : ConversationThread(
              id: thread.id,
              title: thread.title,
              server: authenticated,
              harnessId: thread.harnessId,
              harnessName: thread.harnessName,
              model: thread.model,
              createdAt: thread.createdAt,
              updatedAt: thread.updatedAt,
              messages: thread.messages,
            ).appendTurn(input.trim(), record);
      // Keep a completed turn visible on storage failure; retry only disk I/O,
      // never repeat a potentially side-effecting HTTP request.
      ref.read(threadProvider.notifier).state = updated;
      ref.read(unsavedThreadProvider.notifier).state = updated;
      await savePending();
    } finally {
      ref.read(taskBusyProvider.notifier).state = false;
    }
  }

  Future<void> savePending() async {
    final pending = ref.read(unsavedThreadProvider);
    if (pending == null) return;
    await ref.read(threadStoreProvider).save(pending);
    ref.read(unsavedThreadProvider.notifier).state = null;
    ref.invalidate(historyProvider);
  }
}

class TasksScreen extends ConsumerStatefulWidget {
  const TasksScreen({super.key});
  @override
  ConsumerState<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends ConsumerState<TasksScreen> {
  final _prompt = TextEditingController();
  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final thread = ref.watch(threadProvider);
    final harness = ref.watch(selectedHarnessProvider);
    final busy = ref.watch(taskBusyProvider);
    final unsaved = ref.watch(unsavedThreadProvider) != null;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Text(
                thread == null
                    ? 'Harness: ${harness?.name ?? 'none'}'
                    : '${thread.title} · ${thread.harnessName}',
              ),
              TextField(
                controller: _prompt,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(labelText: 'Prompt'),
                enabled: !busy && !unsaved,
              ),
              Wrap(
                spacing: 12,
                children: [
                  FilledButton(
                    onPressed: busy || unsaved
                        ? null
                        : () async {
                            final runner = ref.read(taskRunnerProvider);
                            try {
                              await runner.submit(_prompt.text);
                              if (mounted) _prompt.clear();
                            } catch (error) {
                              if (mounted) showMessage(ref, error);
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
                  TextButton(
                    onPressed: busy || unsaved
                        ? null
                        : () {
                            ref.read(threadProvider.notifier).state = null;
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
        Expanded(
          child: thread == null
              ? const Center(child: Text('No task history yet.'))
              : ListView.builder(
                  itemCount: thread.messages.length,
                  itemBuilder: (context, index) {
                    final message = thread.messages[index];
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
                            if (message.responseId != null)
                              Text(
                                'response_id=${message.responseId}',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
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
