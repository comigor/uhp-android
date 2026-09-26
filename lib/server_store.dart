part of 'main.dart';

int _lastLocalId = 0;
String newLocalId() {
  final now = DateTime.now().microsecondsSinceEpoch;
  _lastLocalId = now > _lastLocalId ? now : _lastLocalId + 1;
  return '$_lastLocalId';
}

class ServerStore {
  ServerStore(this.preferences);
  final Future<SharedPreferences> Function() preferences;
  static const key = 'servers_v1';

  Future<List<ServerConfig>> load() async {
    final prefs = await preferences();
    final raw = prefs.get(key);
    if (raw == null) return const [];
    try {
      final items = jsonDecode(raw as String) as List<dynamic>;
      final servers = items
          .map(
            (item) =>
                ServerConfig.fromJson(Map<String, dynamic>.from(item as Map)),
          )
          .toList(growable: false);
      if (servers.map((server) => server.id).toSet().length != servers.length) {
        throw const FormatException('Duplicate server IDs');
      }
      return servers;
    } catch (_) {
      // Never log the JSON: profiles contain credentials.
      debugPrint('Discarding malformed or stale server profiles.');
      await prefs.remove(key);
      return const [];
    }
  }

  Future<void> save(List<ServerConfig> servers) async {
    final prefs = await preferences();
    if (!await prefs.setString(
      key,
      jsonEncode(servers.map((s) => s.toJson()).toList()),
    )) {
      throw const AppError('Could not persist server profiles.');
    }
  }
}

final serverStoreProvider = Provider<ServerStore>(
  (ref) => ServerStore(SharedPreferences.getInstance),
);

class ServersController extends AsyncNotifier<List<ServerConfig>> {
  Future<void> _writes = Future<void>.value();

  @override
  Future<List<ServerConfig>> build() => ref.watch(serverStoreProvider).load();

  Future<void> _mutate(List<ServerConfig> Function(List<ServerConfig>) change) {
    final operation = _writes.then((_) async {
      final current = await future;
      final next = List<ServerConfig>.unmodifiable(change(current));
      await ref.read(serverStoreProvider).save(next);
      state = AsyncData(next);
      final selected = ref.read(selectedServerProvider);
      if (selected != null) {
        ref.read(selectedServerProvider.notifier).state = next
            .where((server) => server.id == selected.id)
            .firstOrNull;
      }
    });
    _writes = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<void> add(ServerConfig server) =>
      _mutate((current) => [...current, server]);

  Future<void> updateProfile(ServerConfig server) => _mutate((current) {
    if (!current.any((s) => s.id == server.id)) {
      throw const AppError('This server profile was deleted.');
    }
    return [
      for (final item in current)
        if (item.id == server.id) server else item,
    ];
  });

  Future<void> delete(String id) =>
      _mutate((current) => current.where((s) => s.id != id).toList());

  Future<void> setTestResult(String id, String result) => _mutate((current) {
    return [
      for (final server in current)
        if (server.id == id) server.copyWith(testResult: result) else server,
    ];
  });
}
