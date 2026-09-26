part of 'main.dart';

@immutable
class LiveTurn {
  const LiveTurn({
    required this.input,
    this.progress = const TurnProgress(),
    this.stopping = false,
  });
  final String input;
  final TurnProgress progress;
  final bool stopping;
}

final liveTurnProvider = StateProvider<LiveTurn?>((ref) => null);
final unsavedThreadProvider = StateProvider<ConversationThread?>((ref) => null);
final taskRunnerProvider = Provider<TaskRunner>((ref) {
  final runner = TaskRunner(ref);
  ref.onDispose(runner.dispose);
  return runner;
});

class TaskRunner {
  TaskRunner(this.ref);
  final Ref ref;
  StreamingTurn? _turn;
  ServerConfig? _server;
  Future<void>? _submission;
  TurnStatus? _stopRequested;
  bool _disposed = false;

  Future<void> submit(String input) {
    if (_submission != null) return _submission!;
    if (ref.read(unsavedThreadProvider) != null) {
      return Future.error(
        const AppError('Save the completed turn before continuing.'),
      );
    }
    if (input.trim().isEmpty) {
      return Future.error(const AppError('Enter a prompt first.'));
    }
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
      return Future.error(const AppError('Select a server and harness first.'));
    }
    _stopRequested = null;
    _server = server;
    ref.read(taskBusyProvider.notifier).state = true;
    ref.read(liveTurnProvider.notifier).state = LiveTurn(input: input.trim());
    return _submission = _submit(input.trim(), thread, server, harness);
  }

  Future<void> _submit(
    String input,
    ConversationThread? thread,
    ServerConfig server,
    Harness harness,
  ) async {
    ServerConfig authenticated = server;
    ResponseRecord? record;
    Object? failure;
    try {
      final servers = await ref.read(serversProvider.future);
      if (!servers.any((s) => s.id == server.id)) {
        throw const AppError(
          'The saved server profile was deleted. This thread cannot continue.',
        );
      }
      if (_disposed) return;
      final service = ref.read(uhpServiceProvider);
      if (_stopRequested == null) {
        authenticated =
            server.authMode == AuthMode.console &&
                (server.cookie?.isEmpty ?? true)
            ? await service.login(server)
            : server;
        if (_disposed) return;
        _server = authenticated;
        if (authenticated.cookie != server.cookie) {
          await ref
              .read(serversProvider.notifier)
              .updateCookie(server, authenticated.cookie!);
        }
      }
      if (_disposed) return;
      if (_stopRequested != null) {
        record = ResponseRecord(
          prompt: input,
          output: '',
          responseId: '',
          sessionId: '',
          status: _stopRequested!,
        );
      } else {
        _turn = service.startTurn(
          authenticated,
          ResponseDraft(
            input: input,
            harnessId: harness.id,
            previousResponseId: thread?.lastResponseId,
          ),
        );
        try {
          record = await _turn!.run(
            onProgress: (progress) {
              if (!_disposed) {
                ref.read(liveTurnProvider.notifier).state = LiveTurn(
                  input: input,
                  progress: progress,
                  stopping: _stopRequested != null,
                );
              }
            },
          );
        } catch (error) {
          final progress = _turn!.progress;
          record = ResponseRecord(
            prompt: input,
            output: progress.text,
            responseId: progress.responseId,
            sessionId: progress.sessionId,
            status: _stopRequested ?? TurnStatus.failed,
          );
          if (_stopRequested == null) failure = error;
        }
      }
      if (_disposed) return;
      final updated = thread == null
          ? ConversationThread.start(
              server: authenticated,
              harness: harness,
              prompt: input,
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
            ).appendTurn(input, record);
      ref.read(threadProvider.notifier).state = updated;
      ref.read(liveTurnProvider.notifier).state = null;
      ref.read(unsavedThreadProvider.notifier).state = updated;
      await savePending();
      if (failure != null) throw failure;
    } finally {
      _turn = null;
      _server = null;
      _submission = null;
      if (!_disposed) {
        ref.read(liveTurnProvider.notifier).state = null;
        ref.read(taskBusyProvider.notifier).state = false;
      }
    }
  }

  Future<void> cancel() => _stop(TurnStatus.cancelled, remote: true);
  Future<void> interrupt() => _stop(TurnStatus.interrupted, remote: false);

  Future<void> _stop(TurnStatus status, {required bool remote}) async {
    final submission = _submission;
    if (submission == null ||
        _stopRequested != null ||
        (_turn?.finished ?? false)) {
      return;
    }
    _stopRequested = status;
    final live = ref.read(liveTurnProvider);
    if (live != null) {
      ref.read(liveTurnProvider.notifier).state = LiveTurn(
        input: live.input,
        progress: live.progress,
        stopping: true,
      );
    }
    final turn = _turn;
    final sessionId = turn?.progress.sessionId ?? '';
    // Start the server cancel request, but do not wait for its response to close
    // the stream. A slow cancel endpoint must not leave the SSE connection open.
    final cancellation = remote && _server != null && sessionId.isNotEmpty
        ? ref.read(uhpServiceProvider).cancelSession(_server!, sessionId)
        : Future<void>.value();
    // Attach handlers immediately so either operation may finish first.
    await Future.wait<void>([
      cancellation,
      if (turn != null) turn.stop(status),
      submission,
    ]);
  }

  Future<void> savePending() async {
    final pending = ref.read(unsavedThreadProvider);
    if (pending == null) return;
    await ref.read(threadStoreProvider).save(pending);
    if (_disposed) return;
    ref.read(unsavedThreadProvider.notifier).state = null;
    ref.invalidate(historyProvider);
  }

  void dispose() {
    _disposed = true;
    unawaited(_turn?.stop(TurnStatus.interrupted) ?? Future<void>.value());
  }
}
