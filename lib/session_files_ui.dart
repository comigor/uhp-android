part of 'main.dart';

Future<void> showSessionFiles(
  WidgetRef ref,
  ConversationThread thread, {
  bool changed = false,
}) async {
  final sessionId = thread.serverSessionId;
  if (sessionId == null || sessionId.isEmpty) {
    showMessage(ref, 'Run a task before browsing session files.');
    return;
  }
  final server = ref
      .read(serversProvider)
      .valueOrNull
      ?.where(
        (candidate) =>
            candidate.id == thread.server.id &&
            normalizeBaseUrl(candidate.baseUrl) ==
                normalizeBaseUrl(thread.server.baseUrl),
      )
      .firstOrNull;
  if (server == null) {
    showMessage(ref, 'Restore the saved server profile to browse its files.');
    return;
  }
  final selected = ref.read(selectedServerProvider);
  bool current() {
    if (!ref.context.mounted) return false;
    final active = ref.read(threadProvider);
    final profile = ref
        .read(serversProvider)
        .valueOrNull
        ?.where((candidate) => candidate.id == server.id)
        .firstOrNull;
    final selection = ref.read(selectedServerProvider);
    return active?.id == thread.id &&
        active?.serverSessionId == sessionId &&
        selection?.id == selected?.id &&
        selection?.baseUrl == selected?.baseUrl &&
        profile?.baseUrl == server.baseUrl &&
        profile?.apiKey == server.apiKey &&
        profile?.accessTokenId == server.accessTokenId &&
        profile?.accessToken == server.accessToken;
  }

  if (!current()) {
    showMessage(ref, 'The conversation changed. Open its files again.');
    return;
  }
  await showModalBottomSheet<void>(
    context: ref.context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => SessionFilesSheet(
      server: server,
      sessionId: sessionId,
      changed: changed,
      isCurrent: current,
    ),
  );
}

class SessionFilesSheet extends ConsumerStatefulWidget {
  const SessionFilesSheet({
    super.key,
    required this.server,
    required this.sessionId,
    this.changed = false,
    this.isCurrent,
  });

  final ServerConfig server;
  final String sessionId;
  final bool changed;
  final bool Function()? isCurrent;

  @override
  ConsumerState<SessionFilesSheet> createState() => _SessionFilesSheetState();
}

class _SessionFilesSheetState extends ConsumerState<SessionFilesSheet> {
  late bool _changed;
  List<SessionFile> _files = const [];
  bool _loading = true;
  bool _invalid = false;
  Object? _error;
  int _generation = 0;
  SessionFileDownload? _download;
  String? _downloadName;
  int _received = 0;
  int? _total;
  File? _downloaded;
  String? _mediaType;

  @override
  void initState() {
    super.initState();
    _changed = widget.changed;
    unawaited(_refresh());
  }

  @override
  void didUpdateWidget(covariant SessionFilesSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.server != widget.server ||
        oldWidget.sessionId != widget.sessionId) {
      _download?.cancel();
      _downloaded = null;
      _files = const [];
      unawaited(_refresh());
    }
  }

  @override
  void dispose() {
    _generation++;
    _download?.cancel();
    super.dispose();
  }

  bool _current() => mounted && !_invalid && (widget.isCurrent?.call() ?? true);

  void _checkContext() {
    if (_invalid || widget.isCurrent == null || widget.isCurrent!()) return;
    _download?.cancel();
    setState(() {
      _invalid = true;
      _generation++;
      _loading = false;
      _files = const [];
      _downloaded = null;
      _error = const AppError(
        'The conversation or server profile changed. Close files and reopen.',
      );
    });
  }

  Future<void> _refresh() async {
    if (!_current()) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final files = await ref
          .read(uhpServiceProvider)
          .fetchSessionFiles(
            widget.server,
            widget.sessionId,
            changed: _changed,
          );
      if (!_current() || generation != _generation) return;
      setState(() {
        _files = files;
        _loading = false;
      });
    } catch (error) {
      if (!_current() || generation != _generation) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  Future<void> _startDownload([SessionFile? file]) async {
    if (!_current() || _download != null) return;
    final platform = ref.read(sessionFilePlatformProvider);
    final messengerKey = ref.read(appScaffoldMessengerKeyProvider);
    final service = ref.read(sessionFilesServiceProvider);
    final server = widget.server;
    final sessionId = widget.sessionId;
    void progress(int received, int? total) {
      if (!_current()) return;
      setState(() {
        _received = received;
        _total = total;
      });
    }

    setState(() {
      _error = null;
      _received = 0;
      _total = file?.bytes;
      _downloaded = null;
      _downloadName = file?.filename ?? 'session-files.zip';
      _mediaType = file?.mediaType ?? (file == null ? 'application/zip' : null);
    });
    final operation = file == null
        ? service.archive(
            server,
            sessionId,
            changed: _changed,
            onProgress: progress,
          )
        : service.download(server, sessionId, file, onProgress: progress);
    setState(() {
      _download = operation;
    });
    bool stillCurrent() =>
        _current() && widget.server == server && widget.sessionId == sessionId;
    try {
      final result = await operation.result;
      if (!stillCurrent()) return;
      setState(() {
        _downloaded = result;
      });
      final opened = await platform.openFile(result.path, _mediaType);
      if (!stillCurrent()) return;
      if (!opened) {
        setState(() {
          _error = const AppError(
            'No app can open this file. Use Share file to save or send it.',
          );
        });
      }
    } on SessionFileCancelled {
      if (stillCurrent()) {
        setState(() {
          _error = const AppError('Download cancelled.');
        });
      }
    } catch (error) {
      if (stillCurrent()) {
        setState(() {
          _error = error;
        });
      }
      // Report cleanup failures even if the sheet was dismissed during download.
      if (!mounted && error is! SessionFileCancelled) {
        messengerKey.currentState?.showSnackBar(
          SnackBar(content: Text('$error')),
        );
      }
    } finally {
      if (mounted && identical(_download, operation)) {
        setState(() {
          _download = null;
        });
      }
    }
  }

  Future<void> _share() async {
    final file = _downloaded;
    if (file == null || !_current()) return;
    try {
      await ref
          .read(sessionFilePlatformProvider)
          .shareFile(file.path, _mediaType);
    } catch (error) {
      if (_current()) {
        setState(() {
          _error = error;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isCurrent != null) {
      ref.listen(threadProvider, (_, _) => _checkContext());
      ref.listen(serversProvider, (_, _) => _checkContext());
      ref.listen(selectedServerProvider, (_, _) => _checkContext());
    }
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * .8,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
            child: Row(
              children: [
                Text(
                  'Session files',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Close files',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilterChip(
                  label: const Text('New this turn'),
                  selected: _changed,
                  onSelected: _invalid
                      ? null
                      : (value) {
                          setState(() {
                            _changed = value;
                            _files = const [];
                          });
                          unawaited(_refresh());
                        },
                ),
                TextButton.icon(
                  onPressed:
                      _invalid ||
                          _loading ||
                          _files.isEmpty ||
                          _download != null
                      ? null
                      : () => _startDownload(),
                  icon: const Icon(Icons.folder_zip_outlined),
                  label: const Text('Download all (.zip)'),
                ),
              ],
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '$_error',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (_download != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Downloading $_downloadName'),
                  LinearProgressIndicator(
                    value: _total != null && _total! > 0
                        ? (_received / _total!).clamp(0.0, 1.0)
                        : null,
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${_sessionFileSize(_received)}${_total == null ? '' : ' / ${_sessionFileSize(_total)}'}',
                        ),
                      ),
                      TextButton(
                        onPressed: _download!.cancel,
                        child: const Text('Cancel download'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          if (_downloaded != null)
            TextButton.icon(
              onPressed: _invalid ? null : _share,
              icon: const Icon(Icons.share_outlined),
              label: const Text('Share file'),
            ),
          if (_loading) const LinearProgressIndicator(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: ListView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
                itemCount: _files.length + 1,
                itemBuilder: (context, index) {
                  if (index == 0) {
                    if (!_loading && _files.isEmpty && _error == null) {
                      return Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          _changed ? 'No new files this turn.' : 'No workspace files yet. Run a task to create files.',
                        ),
                      );
                    }
                    if (!_loading && _error != null && !_invalid) {
                      return Center(
                        child: TextButton(
                          onPressed: _refresh,
                          child: const Text('Retry files'),
                        ),
                      );
                    }
                    return const SizedBox.shrink();
                  }
                  final file = _files[index - 1];
                  return ListTile(
                    leading: Icon(_sessionFileIcon(file.mediaType)),
                    title: Text(file.filename),
                    subtitle: Text(
                      [
                        if (file.path.isNotEmpty) file.path,
                        _sessionFileSize(file.bytes),
                      ].join('\n'),
                    ),
                    isThreeLine: file.path.isNotEmpty,
                    trailing: const Icon(Icons.download_outlined),
                    onTap: _invalid || _download != null
                        ? null
                        : () => _startDownload(file),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _sessionFileSize(int? bytes) {
  if (bytes == null) return 'Size unknown';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

IconData _sessionFileIcon(String? mediaType) {
  if (mediaType?.startsWith('image/') ?? false) return Icons.image_outlined;
  if (mediaType?.startsWith('audio/') ?? false) {
    return Icons.audio_file_outlined;
  }
  if (mediaType?.startsWith('video/') ?? false) {
    return Icons.video_file_outlined;
  }
  if (mediaType == 'application/pdf') return Icons.picture_as_pdf_outlined;
  if (mediaType == 'application/zip') return Icons.folder_zip_outlined;
  if (mediaType?.startsWith('text/') ?? false) {
    return Icons.description_outlined;
  }
  return Icons.insert_drive_file_outlined;
}
