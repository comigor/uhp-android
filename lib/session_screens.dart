part of 'main.dart';

bool _conversationBlocked(WidgetRef ref) =>
    ref.read(taskBusyProvider) ||
    ref.read(unsavedThreadProvider) != null ||
    ref.read(feedMutationBusyProvider);

const _sessionManagementBlockedReason =
    'Finish or save the current turn before hiding or restoring sessions.';

Future<void> _openServerSession(
  WidgetRef ref,
  ServerConfig server,
  String sessionId, {
  required bool Function() isCurrent,
  String? harnessName,
}) async {
  bool allowed() => isCurrent() && !_conversationBlocked(ref);
  if (!allowed()) return;
  final service = ref.read(uhpServiceProvider);
  final session = await service.fetchSession(server, sessionId);
  if (!allowed()) return;
  if (session.id != sessionId) {
    throw const AppError(
      'Server returned a different session. Nothing was imported.',
    );
  }
  final turns = await service.fetchSessionTurns(server, sessionId);
  if (!allowed()) return;
  final thread = await ref
      .read(threadStoreProvider)
      .linkServerSession(
        server: server,
        session: session,
        turns: turns,
        harnessName: harnessName ?? session.harnessId,
      );
  if (!allowed()) return;
  ref.read(threadProvider.notifier).state = thread;
  ref.read(selectedHarnessProvider.notifier).state = Harness(
    id: thread.harnessId,
    name: thread.harnessName,
    baseLabel: '',
    defaultModel: thread.model ?? '',
  );
  ref.invalidate(historyProvider);
  ref.read(appDestinationProvider.notifier).state = AppDestination.chat;
  unawaited(
    ref
        .read(appPreferencesProvider.notifier)
        .selectHarness(server.id, thread.harnessId)
        .catchError((Object error) {
          if (ref.context.mounted) showMessage(ref, error);
        }),
  );
}

class SessionsFeed extends ConsumerWidget {
  const SessionsFeed({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final server = ref.watch(selectedServerProvider);
    final filter = ref.watch(
      appPreferencesProvider.select(
        (preferences) => preferences.valueOrNull?.feedFilter ?? 'all',
      ),
    );
    return _ServerSessions(
      key: ValueKey((server, filter, ref.watch(sessionFeedRevisionProvider))),
      server: server,
      filter: filter,
    );
  }
}

class _ServerSessions extends ConsumerStatefulWidget {
  const _ServerSessions({
    super.key,
    required this.server,
    required this.filter,
  });
  final ServerConfig? server;
  final String filter;
  @override
  ConsumerState<_ServerSessions> createState() => _ServerSessionsState();
}

class _ServerSessionsState extends ConsumerState<_ServerSessions> {
  List<ServerSession> _sessions = const [];
  String? _cursor;
  Object? _error;
  Object? _newChatError;
  bool _loading = false;
  bool _opening = false;
  bool _startingChat = false;
  int _generation = 0;

  bool get _onDevice => widget.filter == 'on-device';
  String? get _harnessId => widget.filter.startsWith('harness:')
      ? widget.filter.substring('harness:'.length)
      : null;
  bool get _current =>
      mounted && identical(ref.read(selectedServerProvider), widget.server);

  @override
  void initState() {
    super.initState();
    if (!_onDevice) _load();
    // Shared with Settings; never make a separate connection/test request.
    if (widget.server != null &&
        (ref.read(harnessesProvider).valueOrNull?.isEmpty ?? true) &&
        !ref.read(harnessesProvider).isLoading) {
      unawaited(Future<void>.microtask(_loadHarnesses));
    }
  }

  Future<void> _loadHarnesses() async {
    if (!_current || widget.server == null) return;
    try {
      await ref.read(harnessesProvider.notifier).refresh();
    } catch (_) {
      // The shared provider exposes the error in the feed and Settings.
    }
  }

  Future<void> _refresh() async {
    if (_opening) return;
    if (_onDevice) {
      ref.invalidate(historyProvider);
      await ref.read(historyProvider.future);
    } else {
      await Future.wait([_load(), _loadHarnesses()]);
    }
  }

  Future<void> _load({bool more = false}) async {
    final server = widget.server;
    if (server == null || _onDevice) return;
    final generation = ++_generation;
    final cursor = more ? _cursor : null;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await ref
          .read(uhpServiceProvider)
          .fetchSessions(server, cursor: cursor, harnessId: _harnessId);
      if (!_current || generation != _generation) return;
      final merged = {
        if (more)
          for (final item in _sessions) item.id: item,
        for (final item in page.sessions) item.id: item,
      };
      final items = merged.values.toList();
      items.sort((a, b) {
        if (a.updatedAt == null) return b.updatedAt == null ? 0 : 1;
        if (b.updatedAt == null) return -1;
        return b.updatedAt!.compareTo(a.updatedAt!);
      });
      setState(() {
        _sessions = items;
        _cursor = page.cursor == cursor ? null : page.cursor;
      });
    } catch (error) {
      if (_current && generation == _generation) setState(() => _error = error);
    } finally {
      if (_current && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  String _harnessName(String id) =>
      ref
          .read(harnessesProvider)
          .valueOrNull
          ?.where((harness) => harness.id == id)
          .firstOrNull
          ?.name ??
      id;

  Future<void> _open(ServerSession session) async {
    final server = widget.server;
    if (server == null || _opening || _conversationBlocked(ref)) return;
    final generation = _generation;
    setState(() => _opening = true);
    try {
      await _openServerSession(
        ref,
        server,
        session.id,
        harnessName: _harnessName(session.harnessId),
        isCurrent: () => _current && generation == _generation,
      );
    } catch (error) {
      if (_current) showMessage(ref, error);
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _sessionActions(ServerSession session) async {
    final server = widget.server;
    if (server == null || !_current || _opening) return;
    final hide = await showModalBottomSheet<bool>(
      context: context,
      builder: (context) => Consumer(
        builder: (context, ref, _) {
          final blocked =
              ref.watch(taskBusyProvider) ||
              ref.watch(unsavedThreadProvider) != null;
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    session.title.isEmpty ? session.id : session.title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.visibility_off_outlined),
                  title: const Text('Hide from feed'),
                  subtitle: const Text(
                    'Only on this device. Restore in Settings > Servers.',
                  ),
                  enabled: !blocked,
                  onTap: blocked ? null : () => Navigator.pop(context, true),
                ),
                if (blocked)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(_sessionManagementBlockedReason),
                  ),
              ],
            ),
          );
        },
      ),
    );
    if (hide != true || !_current || _opening || _conversationBlocked(ref)) {
      return;
    }
    try {
      await ref
          .read(appPreferencesProvider.notifier)
          .hideSession(
            server.id,
            session.id,
            session.title.isEmpty ? session.id : session.title,
          );
    } catch (error) {
      if (mounted) showMessage(ref, error);
    }
  }

  Future<void> _selectAllFiltered() async {
    final server = widget.server;
    if (server == null || _opening || _loading || _conversationBlocked(ref)) {
      return;
    }
    setState(() => _opening = true);
    try {
      final cursors = <String>{};
      while (_cursor != null) {
        if (!cursors.add(_cursor!)) {
          throw const AppError(
            'The server repeated a pagination cursor. Refresh and try again.',
          );
        }
        await _load(more: true);
        if (!_current || _conversationBlocked(ref)) return;
        if (_error != null) throw _error!;
      }
      if (!_current || _conversationBlocked(ref)) return;
      final hidden = ref
          .read(appPreferencesProvider)
          .valueOrNull
          ?.hiddenSessions[server.id];
      ref
          .read(feedSelectionProvider.notifier)
          .selectAll(
            _sessions
                .where((session) => !(hidden?.containsKey(session.id) ?? false))
                .map((session) => FeedTarget.remote(server, session)),
          );
    } catch (error) {
      if (mounted) showMessage(ref, error);
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _newChat() async {
    if (_opening || _conversationBlocked(ref)) return;
    setState(() {
      _opening = true;
      _startingChat = true;
      _newChatError = null;
    });
    try {
      await startNewChat(ref);
    } catch (error) {
      if (_current) setState(() => _newChatError = error);
    } finally {
      if (mounted) {
        setState(() {
          _opening = false;
          _startingChat = false;
        });
      }
    }
  }

  Future<void> _filter(String value) async {
    try {
      await ref.read(appPreferencesProvider.notifier).setFeedFilter(value);
    } catch (error) {
      if (mounted) showMessage(ref, error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final harnesses = ref.watch(harnessesProvider);
    final conversationBlocked =
        ref.watch(taskBusyProvider) ||
        ref.watch(unsavedThreadProvider) != null ||
        ref.watch(feedMutationBusyProvider);
    final blocked = conversationBlocked || _opening;
    final error = _error ?? harnesses.error;
    final hiddenSessions = ref.watch(
      appPreferencesProvider.select(
        (preferences) =>
            preferences.valueOrNull?.hiddenSessions[widget.server?.id],
      ),
    );
    final visibleSessions = _sessions
        .where((session) => !(hiddenSessions?.containsKey(session.id) ?? false))
        .toList();
    final selection = ref.watch(feedSelectionProvider);
    final selecting = selection.isNotEmpty;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.server?.name ?? 'On this device',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              IconButton(
                tooltip: 'Refresh sessions',
                onPressed: _loading || _opening ? null : _refresh,
                icon: const Icon(Icons.refresh),
              ),
              FilledButton.icon(
                onPressed: blocked || selecting ? null : _newChat,
                icon: const Icon(Icons.add),
                label: const Text('New chat'),
              ),
            ],
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            spacing: 8,
            children: [
              ChoiceChip(
                label: const Text('All'),
                selected: widget.filter == 'all',
                onSelected: _opening ? null : (_) => _filter('all'),
              ),
              for (final harness in harnesses.valueOrNull ?? const <Harness>[])
                ChoiceChip(
                  label: Text(harness.name),
                  selected: _harnessId == harness.id,
                  onSelected: _opening
                      ? null
                      : (_) => _filter('harness:${harness.id}'),
                ),
              if (_harnessId != null &&
                  !(harnesses.valueOrNull ?? const <Harness>[]).any(
                    (harness) => harness.id == _harnessId,
                  ))
                ChoiceChip(
                  label: Text(_harnessId!),
                  selected: true,
                  onSelected: _opening ? null : (_) => _filter('all'),
                ),
              ChoiceChip(
                label: const Text('On-device'),
                selected: _onDevice,
                onSelected: _opening ? null : (_) => _filter('on-device'),
              ),
            ],
          ),
        ),
        if (selecting && !_onDevice)
          FeedSelectionBar(
            onSelectAll: blocked || _loading ? null : _selectAllFiltered,
          ),
        if (error != null) _FeedErrorCard(error: error, onRetry: _refresh),
        if (_newChatError != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '$_newChatError',
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  onPressed: () =>
                      ref.read(appDestinationProvider.notifier).state =
                          AppDestination.settings,
                  child: const Text('Open Settings'),
                ),
              ],
            ),
          ),
        if (_loading || (_opening && !_startingChat))
          const LinearProgressIndicator(),
        if (conversationBlocked)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Finish or save the current turn before opening another session.',
            ),
          ),
        Expanded(
          child: _onDevice
              ? RefreshIndicator(
                  onRefresh: _refresh,
                  child: const HistoryScreen(),
                )
              : RefreshIndicator(
                  onRefresh: _refresh,
                  child: ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: visibleSessions.length + 1,
                    itemBuilder: (context, index) {
                      if (index == visibleSessions.length) {
                        return Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            children: [
                              if (visibleSessions.isEmpty &&
                                  !_loading &&
                                  _error == null)
                                Text(
                                  widget.server == null
                                      ? 'Add a server in Settings, or browse On-device.'
                                      : 'No server sessions yet.',
                                ),
                              if (_cursor != null)
                                OutlinedButton(
                                  onPressed: _loading || _opening
                                      ? null
                                      : () => _load(more: true),
                                  child: const Text('Load more'),
                                ),
                            ],
                          ),
                        );
                      }
                      final session = visibleSessions[index];
                      final target = FeedTarget.remote(widget.server!, session);
                      final locked = blocked || target.locked;
                      void toggle() {
                        if (!_conversationBlocked(ref) &&
                            !target.locked &&
                            !_opening) {
                          ref
                              .read(feedSelectionProvider.notifier)
                              .toggle(target);
                        }
                      }

                      return Dismissible(
                        key: ValueKey('swipe-${target.key}'),
                        direction: selecting || locked
                            ? DismissDirection.none
                            : DismissDirection.startToEnd,
                        background: Container(
                          color: Theme.of(context)
                              .colorScheme
                              .secondaryContainer,
                          alignment: AlignmentDirectional.centerStart,
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: const Icon(Icons.visibility_off_outlined),
                        ),
                        confirmDismiss: (_) async {
                          if (_conversationBlocked(ref) ||
                              ref.read(feedSelectionProvider).isNotEmpty ||
                              target.locked) {
                            return false;
                          }
                          await manageFeedBatch(ref, FeedBatchAction.hide, [
                            target,
                          ]);
                          return false;
                        },
                        child: ListTile(
                          key: ValueKey('session-${session.id}'),
                          enabled: !blocked,
                          selected: selection.containsKey(target.key),
                          leading: selecting
                              ? Checkbox(
                                  value: selection.containsKey(target.key),
                                  onChanged: locked ? null : (_) => toggle(),
                                )
                              : null,
                          title: Text(
                            session.title.isEmpty ? session.id : session.title,
                          ),
                          subtitle: Text(
                            [
                              _harnessName(session.harnessId),
                              if (session.model.isNotEmpty) session.model,
                              if (session.updatedAt != null)
                                relativeTime(session.updatedAt!),
                            ].where((value) => value.isNotEmpty).join(' · '),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _SessionStatus(status: session.status),
                              if (!selecting)
                                IconButton(
                                  tooltip: 'Session options',
                                  onPressed: locked
                                      ? null
                                      : () => _sessionActions(session),
                                  icon: const Icon(Icons.more_vert),
                                ),
                            ],
                          ),
                          onLongPress: locked ? null : toggle,
                          onTap: blocked
                              ? null
                              : selecting
                              ? (target.locked ? null : toggle)
                              : () => _open(session),
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

class _FeedErrorCard extends ConsumerWidget {
  const _FeedErrorCard({required this.error, required this.onRetry});
  final Object error;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Card(
    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$error', maxLines: 3, overflow: TextOverflow.ellipsis),
          Row(
            children: [
              TextButton(
                onPressed: () async {
                  try {
                    await onRetry();
                  } catch (error) {
                    if (context.mounted) showMessage(ref, error);
                  }
                },
                child: const Text('Retry'),
              ),
              TextButton(
                onPressed: () =>
                    ref.read(appDestinationProvider.notifier).state =
                        AppDestination.settings,
                child: const Text('Edit server'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _SessionStatus extends StatelessWidget {
  const _SessionStatus({required this.status});
  final String status;
  @override
  Widget build(BuildContext context) {
    final normalized = status.toLowerCase();
    final color = switch (normalized) {
      'done' || 'completed' => Colors.green,
      'failed' => Colors.red,
      'cancelled' || 'canceled' => Colors.grey,
      'running' || 'in_progress' => Colors.blue,
      _ => Theme.of(context).colorScheme.onSurfaceVariant,
    };
    return Chip(
      visualDensity: VisualDensity.compact,
      backgroundColor: color.withValues(alpha: 0.12),
      side: BorderSide(color: color.withValues(alpha: 0.4)),
      label: Text(
        normalized == 'running' || normalized == 'in_progress'
            ? '$status · live'
            : status,
        style: TextStyle(color: color),
      ),
    );
  }
}

class _ModelSelection {
  const _ModelSelection(this.model);
  final String? model;
}

class _ModelPicker extends StatefulWidget {
  const _ModelPicker({
    required this.service,
    required this.server,
    required this.harnessId,
    this.selected,
  });
  final UhpService service;
  final ServerConfig server;
  final String harnessId;
  final String? selected;
  @override
  State<_ModelPicker> createState() => _ModelPickerState();
}

class _ModelPickerState extends State<_ModelPicker> {
  late final Future<List<String>> _models = widget.service.fetchModels(
    widget.server,
    harnessId: widget.harnessId,
  );
  late String _selected = widget.selected ?? '';
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Choose model'),
    content: FutureBuilder<List<String>>(
      future: _models,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Text('Cannot load models: ${snapshot.error}');
        }
        if (!snapshot.hasData) {
          return const SizedBox(
            height: 48,
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final models = {if (_selected.isNotEmpty) _selected, ...snapshot.data!};
        return DropdownButtonFormField<String>(
          initialValue: _selected,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Model'),
          items: [
            const DropdownMenuItem(value: '', child: Text('Harness default')),
            for (final model in models.where((m) => m.isNotEmpty))
              DropdownMenuItem(value: model, child: Text(model)),
          ],
          onChanged: (value) => setState(() => _selected = value ?? ''),
        );
      },
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(
          context,
          _ModelSelection(_selected.isEmpty ? null : _selected),
        ),
        child: const Text('Use model'),
      ),
    ],
  );
}

class _HarnessModelEditor extends ConsumerStatefulWidget {
  const _HarnessModelEditor({required this.server, required this.harness});
  final ServerConfig server;
  final Harness harness;
  @override
  ConsumerState<_HarnessModelEditor> createState() =>
      _HarnessModelEditorState();
}

class _HarnessModelEditorState extends ConsumerState<_HarnessModelEditor> {
  Map<String, dynamic>? _detail;
  List<String> _models = const [];
  String _model = '';
  Object? _error;
  bool _loading = true;
  bool _saving = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  bool get _current =>
      mounted &&
      ref.read(selectedServerProvider) != null &&
      identical(ref.read(selectedServerProvider), widget.server);

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final service = ref.read(uhpServiceProvider);
      final detail = await service.fetchHarnessDetail(
        widget.server,
        widget.harness.id,
      );
      if (!_current) return;
      final models = await service.fetchModels(
        widget.server,
        harnessId: widget.harness.id,
      );
      if (!_current) return;
      setState(() {
        _detail = detail;
        _model = '${detail['defaultModel'] ?? detail['default_model'] ?? ''}';
        _models = models;
      });
    } catch (error) {
      if (_current) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    if (!_current || _conversationBlocked(ref)) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(uhpServiceProvider)
          .updateHarnessDefaultModel(
            widget.server,
            widget.harness.id,
            _model.isEmpty ? null : _model,
          );
      if (!_current) return;
      await ref.read(harnessesProvider.notifier).refresh();
      if (mounted && _current) Navigator.pop(context);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final blocked =
        ref.watch(taskBusyProvider) || ref.watch(unsavedThreadProvider) != null;
    return AlertDialog(
      title: Text('Default model · ${widget.harness.name}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_loading) const LinearProgressIndicator(),
            if (_error != null) Text('$_error'),
            if (_detail != null) ...[
              Text(
                'Current model: ${_detail!['defaultModel'] ?? _detail!['default_model'] ?? 'Default'}',
              ),
              Text('maxStep: ${_detail!['maxStep'] ?? '—'}'),
              Text('timeoutSeconds: ${_detail!['timeoutSeconds'] ?? '—'}'),
              DropdownButtonFormField<String>(
                initialValue: _model,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Default model'),
                items: [
                  const DropdownMenuItem(value: '', child: Text('Default')),
                  for (final model in {
                    if (_model.isNotEmpty) _model,
                    ..._models,
                  }.where((m) => m.isNotEmpty))
                    DropdownMenuItem(value: model, child: Text(model)),
                ],
                onChanged: _saving
                    ? null
                    : (value) => setState(() => _model = value ?? ''),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        if (_detail == null && !_loading)
          TextButton(onPressed: _load, child: const Text('Retry')),
        FilledButton(
          onPressed: _detail == null || _loading || _saving || blocked
              ? null
              : _save,
          child: Text(_saving ? 'Saving…' : 'Save'),
        ),
      ],
    );
  }
}
