part of 'main.dart';

@immutable
class LiveTurn {
  LiveTurn({
    required this.input,
    this.progress = const TurnProgress(),
    this.stopping = false,
    List<MessageAttachment> attachments = const [],
  }) : attachments = List.unmodifiable(attachments);
  final String input;
  final TurnProgress progress;
  final bool stopping;
  final List<MessageAttachment> attachments;
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
  AttachmentUpload? _upload;
  bool submissionRecorded = false;
  ServerConfig? _server;
  String? _linkedSessionId;
  Future<void>? _submission;
  TurnStatus? _stopRequested;
  bool _disposed = false;

  Future<void> submit(
    String input, {
    String? model,
    List<PickedAttachment> attachments = const [],
    ConversationThread? initialThread,
    Future<ComposerDraftRollback?> Function()? onAccepted,
  }) {
    if (_submission != null) return _submission!;
    submissionRecorded = false;
    if (ref.read(unsavedThreadProvider) != null) {
      return Future.error(
        const AppError('Save the completed turn before continuing.'),
      );
    }
    if (input.trim().isEmpty && attachments.isEmpty) {
      return Future.error(const AppError('Enter a prompt first.'));
    }
    final thread = ref.read(threadProvider) ?? initialThread;
    if (thread?.hasServerContinuing ?? false) {
      return Future.error(
        const AppError('Waiting for previous turn to finish on server.'),
      );
    }
    final server = thread?.server ?? ref.read(selectedServerProvider);
    final harness = thread == null
        ? ref.read(selectedHarnessProvider)
        : Harness(
            id: thread.serverHarnessId ?? thread.harnessId,
            name: thread.harnessName,
            baseLabel: '',
            defaultModel: thread.model ?? '',
          );
    if (server == null || harness == null) {
      return Future.error(const AppError('Select a server and harness first.'));
    }
    _stopRequested = null;
    _server = server;
    _linkedSessionId = thread?.serverSessionId;
    ref.read(taskBusyProvider.notifier).state = true;
    ref.read(liveTurnProvider.notifier).state = LiveTurn(input: input);
    return _submission = _submit(
      input,
      thread,
      server,
      harness,
      model,
      List.unmodifiable(attachments),
      onAccepted,
    );
  }

  Future<void> _submit(
    String input,
    ConversationThread? thread,
    ServerConfig server,
    Harness harness,
    String? model,
    List<PickedAttachment> attachments,
    Future<ComposerDraftRollback?> Function()? onAccepted,
  ) async {
    ResponseRecord? record;
    Object? failure;
    List<MessageAttachment> uploaded = const [];
    ComposerDraftRollback? rollbackDraft;
    try {
      if (!server.hasApiKey) throw const AppError('API key required');
      final servers = await ref.read(serversProvider.future);
      if (!servers.any((s) => s.id == server.id)) {
        throw const AppError(
          'The saved server profile was deleted. This thread cannot continue.',
        );
      }
      _checkBeforeTurn();
      if (attachments.isNotEmpty) {
        _upload = AttachmentUpload(
          ref.read(httpClientProvider),
          server,
          attachments,
        );
        await _upload!.preflight();
        _checkBeforeTurn();
      }
      final service = ref.read(uhpServiceProvider);
      if (thread?.serverSessionId != null) {
        final session = await service.fetchSession(
          server,
          thread!.serverSessionId!,
        );
        _checkBeforeTurn();
        if (session.id != thread.serverSessionId) {
          throw const AppError('The server returned a different session.');
        }
        thread = thread.refreshServerSession(session);
        ref.read(threadProvider.notifier).state = thread;
        ref.read(unsavedThreadProvider.notifier).state = thread;
        await savePending();
        _checkBeforeTurn();
        if (session.isRunning) {
          throw const AppError(
            'This server session is still running. Refresh it before sending.',
          );
        }
        if (thread.lastResponseId?.trim().isNotEmpty != true) {
          throw const AppError(
            'This server session has no continuation response ID.',
          );
        }
        if (session.harnessId.trim().isEmpty) {
          throw const AppError('This server session has no harness ID.');
        }
      }
      _checkBeforeTurn();
      if (_upload != null) {
        uploaded = await _upload!.run();
        _upload = null;
      }
      _checkBeforeTurn();
      // All validation and attachment preflight/upload have succeeded. Commit
      // the composer clear now, not when the potentially long stream finishes.
      if (onAccepted != null) rollbackDraft = await onAccepted();
      _checkBeforeTurn();
      ref.read(liveTurnProvider.notifier).state = LiveTurn(
        input: input,
        attachments: uploaded,
      );
      _turn = service.startTurn(
        server,
        ResponseDraft(
          input: buildAttachmentInput(input, uploaded),
          harnessId: thread?.serverHarnessId ?? harness.id,
          previousResponseId: thread?.lastResponseId,
          model: model,
        ),
      );
      try {
        // No await separates this point from dispatch; cancellation during the
        // durable clear above still restores the submitted revision.
        rollbackDraft = null;
        record = await _turn!.run(
          onProgress: (progress) {
            if (!_disposed) {
              ref.read(liveTurnProvider.notifier).state = LiveTurn(
                input: input,
                progress: progress,
                stopping: _stopRequested != null,
                attachments: uploaded,
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
      if (_disposed) return;
      if (record.status == TurnStatus.serverContinuing &&
          record.responseId.trim().isEmpty) {
        record = ResponseRecord(
          prompt: record.prompt,
          output: record.output,
          responseId: '',
          sessionId: record.sessionId,
          status: TurnStatus.failed,
          usage: record.usage,
          error:
              'The app backgrounded before the server supplied a response ID. '
              'Check the server session before retrying; the turn may still be running.',
        );
      }
      final updated = thread == null
          ? ConversationThread.start(
              server: server,
              harness: harness,
              prompt: input,
              record: record,
              attachments: uploaded,
            )
          : thread.appendTurn(input, record, attachments: uploaded);
      ref.read(threadProvider.notifier).state = updated;
      submissionRecorded = true;
      ref.read(liveTurnProvider.notifier).state = null;
      ref.read(unsavedThreadProvider.notifier).state = updated;
      await savePending();
      if (failure != null) throw failure;
    } catch (_) {
      if (rollbackDraft != null) await rollbackDraft();
      rethrow;
    } finally {
      _upload?.cancel();
      _upload = null;
      _turn = null;
      _server = null;
      _linkedSessionId = null;
      _submission = null;
      if (!_disposed) {
        ref.read(liveTurnProvider.notifier).state = null;
        ref.read(taskBusyProvider.notifier).state = false;
      }
    }
  }

  void _checkBeforeTurn() {
    if (_disposed || _stopRequested != null) {
      throw const AppError('Submission cancelled. Draft kept for retry.');
    }
  }

  Future<void> cancel() => _stop(TurnStatus.cancelled, remote: true);
  Future<void> background() =>
      _stop(TurnStatus.serverContinuing, remote: false);

  Future<void> _stop(TurnStatus status, {required bool remote}) async {
    final submission = _submission;
    if (submission == null ||
        _stopRequested != null ||
        (_turn?.finished ?? false)) {
      return;
    }
    _stopRequested = status;
    _upload?.cancel();
    final live = ref.read(liveTurnProvider);
    if (live != null) {
      ref.read(liveTurnProvider.notifier).state = LiveTurn(
        input: live.input,
        progress: live.progress,
        stopping: true,
        attachments: live.attachments,
      );
    }
    final turn = _turn;
    final progressSessionId = turn?.progress.sessionId ?? '';
    final sessionId = progressSessionId.isNotEmpty
        ? progressSessionId
        : turn != null
        ? _linkedSessionId ?? ''
        : '';
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
    if (pending.hasServerContinuing) {
      unawaited(ref.read(serverContinuationProvider).checkNow());
    }
  }

  void dispose() {
    _disposed = true;
    _upload?.cancel();
    unawaited(_turn?.stop(TurnStatus.interrupted) ?? Future<void>.value());
  }
}
