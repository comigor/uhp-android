part of 'main.dart';

typedef ComposerDraftRollback = Future<void> Function();

class _ComposerDraftEntry {
  _ComposerDraftEntry(this.initialThread);
  ConversationThread? initialThread;
  String text = '';
  int revision = 0;
  bool dirty = false;
  bool hydrated = false;
}

/// Owns draft I/O independently of widget lifetime and transcript snapshots.
class ComposerDraftController {
  ComposerDraftController({
    required this.store,
    required this.onHydrated,
    required this.onError,
  });

  final ThreadStore store;
  final void Function(String) onHydrated;
  final void Function(Object) onError;
  final _entries = <String, _ComposerDraftEntry>{};
  String? _threadId;
  Timer? _timer;
  bool _disposed = false;
  int _binding = 0;

  String? get threadId => _threadId;
  int get revision => _entries[_threadId]?.revision ?? 0;

  void bind(ConversationThread? thread, {bool initial = false}) {
    if (_disposed || thread?.id == _threadId) return;
    unawaited(flush());
    _threadId = thread?.id;
    final binding = ++_binding;
    if (thread == null) {
      onHydrated('');
      return;
    }
    final entry = _entries.putIfAbsent(
      thread.id,
      () => _ComposerDraftEntry(initial ? thread : null),
    );
    onHydrated(entry.text);
    if (entry.hydrated || entry.revision != 0) return;
    unawaited(_hydrate(thread.id, entry, binding));
  }

  Future<void> _hydrate(
    String id,
    _ComposerDraftEntry entry,
    int binding,
  ) async {
    try {
      final text = await store.readDraft(id);
      if (entry.revision != 0) return;
      entry.text = text;
      entry.hydrated = true;
      if (!_disposed && _threadId == id && _binding == binding) {
        onHydrated(text);
      }
    } catch (error) {
      onError(error);
    }
  }

  void update(String text) {
    if (_disposed) return;
    final entry = _entries[_threadId];
    if (entry == null || entry.text == text) return;
    entry.text = text;
    entry.revision++;
    entry.dirty = true;
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 275), () {
      unawaited(flush());
    });
  }

  Future<void> _save(String id, _ComposerDraftEntry entry) async {
    final revision = entry.revision;
    await store.saveDraft(id, entry.text, initialThread: entry.initialThread);
    entry.initialThread = null;
    if (entry.revision == revision) entry.dirty = false;
  }

  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    for (final item in _entries.entries.toList()) {
      if (!item.value.dirty) continue;
      try {
        await _save(item.key, item.value);
      } catch (error) {
        // Keep dirty values available for the next flush, and report failures
        // through the app messenger even if the composer has been disposed.
        onError(error);
      }
    }
  }

  Future<ComposerDraftRollback?> clearAccepted(
    String id,
    int submittedRevision,
  ) async {
    final entry = _entries[id];
    if (entry == null || entry.revision != submittedRevision) return null;
    if (_threadId == id) _timer?.cancel();
    final previous = entry.text;
    entry.text = '';
    entry.revision++;
    entry.dirty = true;
    final clearingRevision = entry.revision;
    try {
      await _save(id, entry);
    } catch (_) {
      if (entry.revision == clearingRevision) {
        entry.text = previous;
        entry.revision++;
        entry.dirty = true;
      }
      rethrow;
    }
    if (!_disposed && _threadId == id && entry.revision == clearingRevision) {
      onHydrated('');
    }
    return () async {
      // Restore only this cancelled pre-dispatch clear, never newer typing.
      if (entry.revision != clearingRevision) return;
      entry.text = previous;
      entry.revision++;
      entry.dirty = true;
      if (!_disposed && _threadId == id) onHydrated(previous);
      await _save(id, entry);
    };
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(flush());
  }
}
