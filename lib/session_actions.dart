part of 'main.dart';

@immutable
class SessionShare {
  const SessionShare({required this.enabled, required this.token});

  final bool enabled;
  final String? token;

  factory SessionShare.fromJson(Object? payload) {
    final data = _serverObject(payload, 'session share');
    final enabled = data['enabled'];
    final token = data['token'];
    if (enabled is! bool ||
        (token != null && token is! String) ||
        (enabled && (token is! String || token.isEmpty)) ||
        (token is String &&
            token.isNotEmpty &&
            (token.length > 256 ||
                !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(token)))) {
      throw const AppError('Server returned an invalid session share.');
    }
    return SessionShare(enabled: enabled, token: token as String?);
  }

  Uri publicUri(ServerConfig server) {
    if (!enabled || token == null || token!.isEmpty) {
      throw const AppError('Publish this session before sharing a link.');
    }
    final base = Uri.parse(normalizeBaseUrl(server.baseUrl));
    if (!const {'http', 'https'}.contains(base.scheme) || base.host.isEmpty) {
      throw const AppError('The saved server address is invalid.');
    }
    // The public viewer is a UI route, not an API URL. Never trust response.url
    // or carry user info, queries, fragments, or profile credentials into it.
    return Uri(
      scheme: base.scheme,
      host: base.host,
      port: base.hasPort ? base.port : null,
      path: '${base.path}/share/$token',
    );
  }
}

extension SessionActionsApi on UhpService {
  Future<SessionShare> fetchSessionShare(
    ServerConfig server,
    String sid,
  ) async => SessionShare.fromJson(
    await _serverJson(
      server,
      'GET',
      '/v1/sessions/${Uri.encodeComponent(sid)}/share',
    ),
  );

  Future<SessionShare> setSessionShare(
    ServerConfig server,
    String sid, {
    required bool enabled,
  }) async {
    final share = SessionShare.fromJson(
      await _serverJson(
        server,
        'POST',
        '/v1/sessions/${Uri.encodeComponent(sid)}/share',
        body: {'enabled': enabled},
      ),
    );
    if (share.enabled != enabled) {
      throw const AppError('Server did not apply the requested share state.');
    }
    return share;
  }

  Future<void> cancelSessionStrict(ServerConfig server, String sid) async {
    final abort = Completer<void>();
    final request = http.AbortableRequest(
      'POST',
      buildApiUri(
        server.baseUrl,
        '/v1/sessions/${Uri.encodeComponent(sid)}/cancel',
      ),
      abortTrigger: abort.future,
    );
    try {
      final response = await _ProfileClient(_client, server)
          .send(request)
          .then(http.Response.fromStream)
          .timeout(UhpService.timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw ApiException(
          response.statusCode,
          extractErrorBody(response.body),
        );
      }
    } finally {
      abort.complete();
    }
  }
}

bool _linkedSession(ConversationThread thread) =>
    thread.serverSessionId?.trim().isNotEmpty ?? false;

class _SessionActionTarget {
  const _SessionActionTarget(this.thread, this.server);
  final ConversationThread thread;
  final ServerConfig server;

  bool isCurrent(WidgetRef ref) {
    final current = ref.read(threadProvider);
    return ref.context.mounted &&
        identical(ref.read(selectedServerProvider), server) &&
        ref.read(appDestinationProvider) == AppDestination.chat &&
        current?.id == thread.id &&
        current?.serverSessionId == thread.serverSessionId &&
        current?.server.id == server.id &&
        normalizeBaseUrl(current!.server.baseUrl) ==
            normalizeBaseUrl(server.baseUrl);
  }
}

_SessionActionTarget? _sessionActionTarget(
  WidgetRef ref,
  ConversationThread thread,
) {
  final server = ref.read(selectedServerProvider);
  if (!_linkedSession(thread) || server == null) return null;
  final target = _SessionActionTarget(thread, server);
  return target.isCurrent(ref) ? target : null;
}

class SessionActionsMenu extends ConsumerWidget {
  const SessionActionsMenu({super.key, required this.thread});
  final ConversationThread thread;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!_linkedSession(thread)) return const SizedBox.shrink();
    final blocked =
        ref.watch(taskBusyProvider) || ref.watch(unsavedThreadProvider) != null;
    return PopupMenuButton<String>(
      tooltip: 'Session actions',
      onSelected: (action) async {
        if (action == 'share') {
          await showSessionShare(ref, thread);
        } else {
          final target = _sessionActionTarget(ref, thread);
          if (target == null || _conversationBlocked(ref)) return;
          await showDialog<void>(
            context: context,
            builder: (_) => _CancelSessionDialog(target: target),
          );
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem(value: 'share', child: Text('Share…')),
        PopupMenuItem(
          value: 'cancel',
          enabled: !blocked,
          child: Text(
            'Cancel session',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      ],
    );
  }
}

Future<void> showSessionShare(WidgetRef ref, ConversationThread thread) async {
  final target = _sessionActionTarget(ref, thread);
  if (target == null) return;
  await showDialog<void>(
    context: ref.context,
    builder: (_) => _SessionShareDialog(target: target),
  );
}

class _SessionShareDialog extends ConsumerStatefulWidget {
  const _SessionShareDialog({required this.target});
  final _SessionActionTarget target;

  @override
  ConsumerState<_SessionShareDialog> createState() =>
      _SessionShareDialogState();
}

class _SessionShareDialogState extends ConsumerState<_SessionShareDialog> {
  SessionShare? _share;
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool? enabled}) async {
    if (!widget.target.isCurrent(ref)) return;
    setState(() {
      _loading = true;
      _error = null;
      _share = null;
    });
    try {
      final service = ref.read(uhpServiceProvider);
      final target = widget.target;
      final share = enabled == null
          ? await service.fetchSessionShare(
              target.server,
              target.thread.serverSessionId!,
            )
          : await service.setSessionShare(
              target.server,
              target.thread.serverSessionId!,
              enabled: enabled,
            );
      if (!mounted || !target.isCurrent(ref)) return;
      if (share.enabled) share.publicUri(target.server);
      setState(() => _share = share);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _sendLink({required bool copy}) async {
    if (_loading || !widget.target.isCurrent(ref)) return;
    final share = _share;
    if (share == null || !share.enabled) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final link = share.publicUri(widget.target.server).toString();
      if (copy) {
        await Clipboard.setData(ClipboardData(text: link));
      } else {
        await ref.read(sessionFilePlatformProvider).shareText(link);
      }
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(threadProvider);
    ref.watch(selectedServerProvider);
    ref.watch(appDestinationProvider);
    final current = widget.target.isCurrent(ref);
    final enabled = _share?.enabled ?? false;
    final allowed = current && !_loading;
    return AlertDialog(
      title: const Text('Share session'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Anyone with the public link can read this conversation and its files. Publish only content you want to make public.',
            ),
            const SizedBox(height: 16),
            if (!current)
              const Text(
                'The active session changed. Close this dialog and try again.',
              )
            else if (_loading)
              const LinearProgressIndicator()
            else if (_error != null)
              Text(
                '$_error',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              )
            else if (enabled)
              SelectableText(_share!.publicUri(widget.target.server).toString())
            else
              const Text('This session is not public.'),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        if (_error != null)
          TextButton(
            onPressed: allowed ? () => _load() : null,
            child: const Text('Retry'),
          ),
        if (_share != null && !enabled)
          FilledButton(
            onPressed: allowed ? () => _load(enabled: true) : null,
            child: const Text('Publish link'),
          ),
        if (enabled) ...[
          TextButton(
            onPressed: allowed ? () => _load(enabled: false) : null,
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Revoke link'),
          ),
          TextButton(
            onPressed: allowed ? () => _sendLink(copy: true) : null,
            child: const Text('Copy link'),
          ),
          FilledButton(
            onPressed: allowed ? () => _sendLink(copy: false) : null,
            child: const Text('Share link'),
          ),
        ],
      ],
    );
  }
}

class _CancelSessionDialog extends ConsumerStatefulWidget {
  const _CancelSessionDialog({required this.target});
  final _SessionActionTarget target;

  @override
  ConsumerState<_CancelSessionDialog> createState() =>
      _CancelSessionDialogState();
}

class _CancelSessionDialogState extends ConsumerState<_CancelSessionDialog> {
  bool _sending = false;
  Object? _error;

  Future<void> _cancel() async {
    if (_sending ||
        !widget.target.isCurrent(ref) ||
        _conversationBlocked(ref)) {
      return;
    }
    final container = ProviderScope.containerOf(context, listen: false);
    final target = widget.target;
    setState(() {
      _sending = true;
      _error = null;
    });
    // Own the existing submission/navigation guard until the request settles.
    container.read(taskBusyProvider.notifier).state = true;
    try {
      await container
          .read(uhpServiceProvider)
          .cancelSessionStrict(target.server, target.thread.serverSessionId!);
      container.read(sessionFeedRevisionProvider.notifier).state++;
      if (!mounted ||
          !target.isCurrent(ref) ||
          container.read(unsavedThreadProvider) != null) {
        return;
      }
      // Do not fabricate terminal messages or erase durable continuing turns.
      // Their response reconciliation remains authoritative after cancellation.
      container.read(threadProvider.notifier).state = null;
      container.read(appDestinationProvider.notifier).state =
          AppDestination.feed;
      Navigator.pop(context);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      container.read(taskBusyProvider.notifier).state = false;
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(threadProvider);
    ref.watch(selectedServerProvider);
    ref.watch(appDestinationProvider);
    final blocked =
        ref.watch(taskBusyProvider) || ref.watch(unsavedThreadProvider) != null;
    final current = widget.target.isCurrent(ref);
    return PopScope(
      canPop: !_sending,
      child: AlertDialog(
        title: const Text('Cancel session?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Stop the running work on the server? The conversation and its files will remain available.',
            ),
            if (!current)
              const Text(
                'The active session changed. Close this dialog and try again.',
              ),
            if (blocked && !_sending)
              const Text(
                'Finish or save the current turn before cancelling the session.',
              ),
            if (_sending) const LinearProgressIndicator(),
            if (_error != null)
              Text(
                '$_error',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: _sending ? null : () => Navigator.pop(context),
            child: const Text('Keep session'),
          ),
          FilledButton(
            onPressed: current && !blocked && !_sending ? _cancel : null,
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Cancel session'),
          ),
        ],
      ),
    );
  }
}
