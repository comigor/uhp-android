part of 'main.dart';

bool _conversationBlocked(WidgetRef ref) =>
    ref.read(taskBusyProvider) || ref.read(unsavedThreadProvider) != null;

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
  ref.read(selectedTabProvider.notifier).state = AppTab.tasks;
}

class SessionsScreen extends ConsumerWidget {
  const SessionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final server = ref.watch(selectedServerProvider);
    if (server == null) {
      return const Center(child: Text('Select a server to browse sessions.'));
    }
    return _ServerSessions(key: ObjectKey(server), server: server);
  }
}

class _ServerSessions extends ConsumerStatefulWidget {
  const _ServerSessions({super.key, required this.server});
  final ServerConfig server;
  @override
  ConsumerState<_ServerSessions> createState() => _ServerSessionsState();
}

class _ServerSessionsState extends ConsumerState<_ServerSessions> {
  List<ServerSession> _sessions = const [];
  List<Harness> _harnesses = const [];
  String? _harnessId;
  String? _cursor;
  Object? _error;
  Object? _harnessError;
  bool _loading = false;
  bool _opening = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
    _loadHarnesses();
  }

  bool get _current =>
      mounted &&
      ref.read(selectedServerProvider) != null &&
      identical(ref.read(selectedServerProvider), widget.server);

  Future<void> _loadHarnesses() async {
    try {
      final items = await ref
          .read(uhpServiceProvider)
          .fetchHarnesses(widget.server);
      if (_current) {
        setState(() {
          _harnesses = items;
          _harnessError = null;
        });
      }
    } catch (error) {
      if (_current) setState(() => _harnessError = error);
    }
  }

  Future<void> _load({bool more = false}) async {
    final generation = ++_generation;
    final cursor = more ? _cursor : null;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await ref
          .read(uhpServiceProvider)
          .fetchSessions(widget.server, cursor: cursor, harnessId: _harnessId);
      if (!_current || generation != _generation) return;
      setState(() {
        if (more) {
          final merged = {for (final item in _sessions) item.id: item};
          for (final item in page.sessions) {
            merged[item.id] = item;
          }
          _sessions = merged.values.toList(growable: false);
        } else {
          _sessions = page.sessions;
        }
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

  String _harnessName(String id) {
    for (final harness in _harnesses) {
      if (harness.id == id) return harness.name;
    }
    return id;
  }

  Future<void> _open(ServerSession session) async {
    if (_opening || _conversationBlocked(ref)) return;
    final generation = _generation;
    setState(() => _opening = true);
    try {
      await _openServerSession(
        ref,
        widget.server,
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

  @override
  Widget build(BuildContext context) {
    final blocked =
        ref.watch(taskBusyProvider) ||
        ref.watch(unsavedThreadProvider) != null ||
        _opening;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: _harnessId ?? '',
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Harness filter',
                  ),
                  items: [
                    const DropdownMenuItem(
                      value: '',
                      child: Text('All harnesses'),
                    ),
                    for (final harness in _harnesses)
                      DropdownMenuItem(
                        value: harness.id,
                        child: Text(harness.name),
                      ),
                  ],
                  onChanged: _opening
                      ? null
                      : (value) {
                          setState(() {
                            _harnessId = value == '' ? null : value;
                            _sessions = [];
                            _cursor = null;
                          });
                          _load();
                        },
                ),
              ),
              IconButton(
                tooltip: 'Refresh sessions',
                onPressed: _loading || _opening
                    ? null
                    : () {
                        _load();
                        _loadHarnesses();
                      },
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        if (_loading || _opening) const LinearProgressIndicator(),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async {
              if (_opening) return;
              await Future.wait([_load(), _loadHarnesses()]);
            },
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: _sessions.length + 1,
              itemBuilder: (context, index) {
                if (index == _sessions.length) {
                  return Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        if (_harnessError != null)
                          Text('Harness names unavailable: $_harnessError'),
                        if (_error != null)
                          Text('Cannot load sessions: $_error'),
                        if (_sessions.isEmpty && !_loading && _error == null)
                          const Text('No server sessions.'),
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
                final session = _sessions[index];
                return ListTile(
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
                  trailing: _SessionStatus(status: session.status),
                  onTap: blocked ? null : () => _open(session),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
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
