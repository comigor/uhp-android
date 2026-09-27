part of 'main.dart';

@immutable
class AppPreferences {
  AppPreferences({
    this.lastServerId,
    Map<String, String> lastHarnessIds = const {},
    this.feedFilter = 'all',
    Map<String, Map<String, String>> hiddenSessions = const {},
  }) : lastHarnessIds = Map.unmodifiable(lastHarnessIds),
       hiddenSessions = Map.unmodifiable({
         for (final entry in hiddenSessions.entries)
           entry.key: Map<String, String>.unmodifiable(entry.value),
       });

  final String? lastServerId;
  final Map<String, String> lastHarnessIds;
  final String feedFilter;
  final Map<String, Map<String, String>> hiddenSessions;

  AppPreferences copyWith({
    String? lastServerId,
    Map<String, String>? lastHarnessIds,
    String? feedFilter,
    Map<String, Map<String, String>>? hiddenSessions,
  }) => AppPreferences(
    lastServerId: lastServerId ?? this.lastServerId,
    lastHarnessIds: lastHarnessIds ?? this.lastHarnessIds,
    feedFilter: feedFilter ?? this.feedFilter,
    hiddenSessions: hiddenSessions ?? this.hiddenSessions,
  );

  Map<String, dynamic> toJson() => {
    'lastServerId': lastServerId,
    'lastHarnessIds': lastHarnessIds,
    'feedFilter': feedFilter,
    'hiddenSessions': hiddenSessions,
  };

  factory AppPreferences.fromJson(Map<String, dynamic> json) {
    final serverId = json['lastServerId'];
    final harnessIds = json['lastHarnessIds'];
    final filter = json['feedFilter'];
    final hidden = json['hiddenSessions'];
    return AppPreferences(
      lastServerId: serverId is String && serverId.isNotEmpty ? serverId : null,
      lastHarnessIds: {
        if (harnessIds is Map)
          for (final entry in harnessIds.entries)
            if (entry.key is String &&
                (entry.key as String).isNotEmpty &&
                entry.value is String &&
                (entry.value as String).isNotEmpty)
              entry.key as String: entry.value as String,
      },
      feedFilter: filter is String && _isFeedFilter(filter) ? filter : 'all',
      hiddenSessions: {
        if (hidden is Map)
          for (final entry in hidden.entries)
            if (entry.key is String &&
                (entry.key as String).isNotEmpty &&
                entry.value is Map)
              entry.key as String: {
                for (final session in (entry.value as Map).entries)
                  if (session.key is String &&
                      (session.key as String).isNotEmpty &&
                      session.value is String)
                    session.key as String: session.value as String,
              },
      },
    );
  }
}

bool _isFeedFilter(String value) =>
    value == 'all' ||
    value == 'on-device' ||
    (value.startsWith('harness:') && value.length > 'harness:'.length);

class AppPreferencesStore {
  AppPreferencesStore(this.preferences);

  final Future<SharedPreferences> Function() preferences;
  static const key = 'app_preferences_v1';

  Future<AppPreferences> load() async {
    final prefs = await preferences();
    final raw = prefs.get(key);
    if (raw == null) return AppPreferences();
    try {
      return AppPreferences.fromJson(
        jsonDecode(raw as String) as Map<String, dynamic>,
      );
    } catch (_) {
      return AppPreferences();
    }
  }

  Future<void> save(AppPreferences value) async {
    final prefs = await preferences();
    if (!await prefs.setString(key, jsonEncode(value.toJson()))) {
      throw const AppError('Could not persist app preferences.');
    }
  }
}

final appPreferencesStoreProvider = Provider<AppPreferencesStore>(
  (ref) => AppPreferencesStore(SharedPreferences.getInstance),
);

final appPreferencesProvider =
    AsyncNotifierProvider<AppPreferencesController, AppPreferences>(
      AppPreferencesController.new,
    );

class AppPreferencesController extends AsyncNotifier<AppPreferences> {
  Future<void> _writes = Future<void>.value();

  @override
  Future<AppPreferences> build() =>
      ref.watch(appPreferencesStoreProvider).load();

  Future<void> _mutate(AppPreferences Function(AppPreferences) change) {
    final operation = _writes.then((_) async {
      final current = await future;
      final next = change(current);
      await ref.read(appPreferencesStoreProvider).save(next);
      state = AsyncData(next);
    });
    _writes = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<void> selectServer(String id) =>
      _mutate((current) => current.copyWith(lastServerId: id));

  Future<void> selectHarness(String serverId, String harnessId) => _mutate(
    (current) => current.copyWith(
      lastHarnessIds: {...current.lastHarnessIds, serverId: harnessId},
    ),
  );

  Future<void> setFeedFilter(String value) => _mutate(
    (current) =>
        current.copyWith(feedFilter: _isFeedFilter(value) ? value : 'all'),
  );

  Future<void> hideSession(String serverId, String sessionId, String title) =>
      _mutate(
        (current) => current.copyWith(
          hiddenSessions: {
            ...current.hiddenSessions,
            serverId: {...?current.hiddenSessions[serverId], sessionId: title},
          },
        ),
      );

  Future<void> restoreSession(String serverId, String sessionId) =>
      _mutate((current) {
        final sessions = {...?current.hiddenSessions[serverId]}
          ..remove(sessionId);
        final hidden = {...current.hiddenSessions};
        if (sessions.isEmpty) {
          hidden.remove(serverId);
        } else {
          hidden[serverId] = sessions;
        }
        return current.copyWith(hiddenSessions: hidden);
      });
}
