part of 'main.dart';

final serverContinuationProvider = Provider<ServerContinuationController>((
  ref,
) {
  final controller = ServerContinuationController(ref);
  ref.onDispose(controller.dispose);
  return controller;
});

/// Owns only foreground work for persisted, unresolved responses. Pausing
/// cancels both the next check and every active HTTP request in this generation.
class ServerContinuationController {
  ServerContinuationController(this.ref, {this.schedule = Timer.new});

  final Ref ref;
  final Timer Function(Duration, void Function()) schedule;
  Timer? _timer;
  Completer<void>? _abort;
  Future<void>? _work;
  bool _resumed = false;
  bool _disposed = false;
  bool _checkAgain = false;
  int _generation = 0;

  Future<void> resume() {
    if (_disposed) return Future<void>.value();
    _resumed = true;
    return checkNow();
  }

  void pause() {
    _resumed = false;
    _generation++;
    _timer?.cancel();
    _timer = null;
    final abort = _abort;
    _abort = null;
    if (abort != null && !abort.isCompleted) abort.complete();
    _work = null;
    _checkAgain = false;
  }

  bool _current(int generation) =>
      !_disposed && _resumed && generation == _generation;

  Future<void> checkNow() {
    if (!_resumed || _disposed) return Future<void>.value();
    _timer?.cancel();
    _timer = null;
    final work = _work;
    if (work != null) {
      // A turn may finish saving while discovery is in flight. Scan once more
      // after that work, rather than losing the newly persisted response.
      _checkAgain = true;
      return work;
    }
    final abort = Completer<void>();
    _abort = abort;
    return _work = _poll(_generation, abort.future);
  }

  Future<void> _poll(int generation, Future<void> abort) async {
    var unresolved = false;
    try {
      final threads = await ref.read(threadStoreProvider).continuingThreads();
      if (!_current(generation) || threads.isEmpty) return;
      unresolved = true;
      final servers = await ref.read(serversProvider.future);
      if (!_current(generation)) return;
      final pending = await Future.wait([
        for (final thread in threads)
          for (final message in thread.messages)
            if (message.role == 'assistant' &&
                message.status == TurnStatus.serverContinuing)
              _refresh(thread, message, servers, generation, abort),
      ]);
      unresolved = pending.any((value) => value);
    } catch (error) {
      if (_current(generation)) _showError(error);
    } finally {
      if (_current(generation)) {
        _work = null;
        _abort = null;
        if (_checkAgain) {
          _checkAgain = false;
          unawaited(checkNow());
        } else if (unresolved) {
          _timer = schedule(const Duration(seconds: 5), () {
            _timer = null;
            unawaited(checkNow());
          });
        }
      }
    }
  }

  Future<bool> _refresh(
    ConversationThread thread,
    ThreadMessage message,
    List<ServerConfig> servers,
    int generation,
    Future<void> abort,
  ) async {
    try {
      final server = servers
          .where(
            (candidate) =>
                candidate.id == thread.server.id &&
                normalizeBaseUrl(candidate.baseUrl) ==
                    normalizeBaseUrl(thread.server.baseUrl),
          )
          .firstOrNull;
      if (server == null) {
        throw const AppError(
          'Restore the saved server profile to check its continuing turn.',
        );
      }
      final responseId = message.responseId;
      if (responseId == null || responseId.isEmpty) {
        throw const AppError('The continuing turn has no response ID.');
      }
      final record = await ref
          .read(uhpServiceProvider)
          .fetchResponse(server, responseId, abortTrigger: abort);
      if (!_current(generation)) return false;
      final updated = await ref
          .read(threadStoreProvider)
          .settleResponse(thread.id, responseId, record);
      if (!_current(generation) || updated == null) return false;
      final pending = updated.messages.any(
        (item) =>
            item.responseId == responseId &&
            item.status == TurnStatus.serverContinuing,
      );
      if (!pending) {
        if (ref.read(threadProvider)?.id == updated.id &&
            ref.read(unsavedThreadProvider)?.id != updated.id) {
          ref.read(threadProvider.notifier).state = updated;
        }
        ref.invalidate(historyProvider);
      }
      return pending;
    } catch (error) {
      if (!_current(generation)) return false;
      // Transport/auth failures are not a terminal response record. Retain the
      // durable pending turn so a later foreground check can recover it.
      _showError(error);
      return true;
    }
  }

  void _showError(Object error) {
    ref
        .read(appScaffoldMessengerKeyProvider)
        .currentState
        ?.showSnackBar(SnackBar(content: Text('$error')));
  }

  void dispose() {
    pause();
    _disposed = true;
  }
}
