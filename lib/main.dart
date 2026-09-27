import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'update_ui.dart';
import 'updater.dart';

part 'server_store.dart';
part 'thread_store.dart';
part 'screens.dart';
part 'streaming.dart';
part 'turn_runner.dart';
part 'auth_client.dart';
part 'server_api.dart';
part 'session_screens.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: UhpApp()));
}

enum AppTab { servers, harnesses, tasks, history, sessions }

enum TurnStatus { running, completed, cancelled, interrupted, failed }

const demoServer = ServerConfig(
  name: 'HarnessRouter demo',
  baseUrl: 'https://your-uhp-server.example',
);

@immutable
class ServerConfig {
  const ServerConfig({
    this.id = '',
    required this.name,
    required this.baseUrl,
    this.accessTokenId,
    this.accessToken,
    this.apiKey,
    this.testResult,
  });

  final String id;
  final String name;
  final String baseUrl;
  final String? accessTokenId;
  final String? accessToken;
  final String? apiKey;
  final String? testResult;

  bool get hasPangolin =>
      (accessTokenId?.trim().isNotEmpty ?? false) &&
      (accessToken?.trim().isNotEmpty ?? false);
  bool get hasApiKey => apiKey?.trim().isNotEmpty ?? false;

  ServerConfig copyWith({String? name, String? baseUrl, String? testResult}) =>
      ServerConfig(
        id: id,
        name: name ?? this.name,
        baseUrl: baseUrl ?? this.baseUrl,
        accessTokenId: accessTokenId,
        accessToken: accessToken,
        apiKey: apiKey,
        testResult: testResult ?? this.testResult,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'baseUrl': baseUrl,
    'accessTokenId': accessTokenId,
    'accessToken': accessToken,
    'apiKey': apiKey,
    'testResult': testResult,
  };

  factory ServerConfig.fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String;
    if (id.isEmpty) throw const FormatException('Missing server ID');
    // Legacy modes hid the other credentials; do not silently enable those.
    final legacyMode = json['authMode'] ?? json['mode'];
    return ServerConfig(
      id: id,
      name: json['name'] as String? ?? '',
      baseUrl: json['baseUrl'] as String? ?? '',
      accessTokenId: legacyMode == 'console'
          ? null
          : json['accessTokenId'] as String?,
      accessToken: legacyMode == 'console'
          ? null
          : json['accessToken'] as String?,
      apiKey: json['apiKey'] as String?,
      testResult: json['testResult'] as String?,
    );
  }
}

@immutable
class Harness {
  const Harness({
    required this.id,
    required this.name,
    required this.baseLabel,
    required this.defaultModel,
  });

  final String id;
  final String name;
  final String baseLabel;
  final String defaultModel;

  factory Harness.fromJson(Map<String, dynamic> json) {
    return Harness(
      id: '${json['id'] ?? json['harness_id'] ?? json['name'] ?? ''}',
      name: '${json['name'] ?? json['label'] ?? json['id'] ?? ''}',
      baseLabel: '${json['base_label'] ?? json['baseLabel'] ?? '-'}',
      defaultModel: '${json['default_model'] ?? json['defaultModel'] ?? '-'}',
    );
  }
}

@immutable
class ResponseRecord {
  const ResponseRecord({
    required this.prompt,
    required this.output,
    required this.responseId,
    required this.sessionId,
    this.status = TurnStatus.completed,
    this.usage,
  });

  final String prompt;
  final String output;
  final String responseId;
  final String sessionId;
  final TurnStatus status;
  final TokenUsage? usage;
}

@immutable
class AppError implements Exception {
  const AppError(this.message);

  final String message;

  @override
  String toString() => message;
}

final uhpServiceProvider = Provider<UhpService>((ref) {
  return UhpService(ref.watch(httpClientProvider));
});

final updateServiceProvider = Provider<UpdateService>((ref) {
  return UpdateService(ref.watch(httpClientProvider));
});

final httpClientProvider = Provider<http.Client>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return client;
});

final snackbarControllerProvider = Provider<SnackbarController>((ref) {
  return SnackbarController();
});

final appScaffoldMessengerKeyProvider =
    Provider<GlobalKey<ScaffoldMessengerState>>((ref) {
      return GlobalKey<ScaffoldMessengerState>();
    });

final serversProvider =
    AsyncNotifierProvider<ServersController, List<ServerConfig>>(
      ServersController.new,
    );

final selectedServerProvider = StateProvider<ServerConfig?>((ref) => null);
final selectedTabProvider = StateProvider<AppTab>((ref) => AppTab.servers);
final selectedHarnessProvider = StateProvider<Harness?>((ref) => null);
final harnessesProvider =
    StateNotifierProvider<HarnessesController, AsyncValue<List<Harness>>>((
      ref,
    ) {
      ref.watch(selectedServerProvider);
      return HarnessesController(ref);
    });
final threadProvider = StateProvider<ConversationThread?>((ref) => null);
final threadStoreProvider = Provider<ThreadStore>(
  (ref) => ThreadStore(getApplicationDocumentsDirectory),
);
final historyProvider = FutureProvider.autoDispose<List<ThreadSummary>>(
  (ref) => ref.watch(threadStoreProvider).loadIndex(),
);
final taskBusyProvider = StateProvider<bool>((ref) => false);

class HarnessesController extends StateNotifier<AsyncValue<List<Harness>>> {
  HarnessesController(this._ref) : super(const AsyncData(<Harness>[]));

  final Ref _ref;

  int _generation = 0;

  Future<void> refresh() async {
    final server = _ref.read(selectedServerProvider);
    if (server == null) {
      throw const AppError('Select a server first.');
    }
    state = const AsyncLoading();
    final generation = ++_generation;
    try {
      final service = _ref.read(uhpServiceProvider);
      final harnesses = await service.fetchHarnesses(server);
      if (mounted && generation == _generation) state = AsyncData(harnesses);
    } catch (error, stackTrace) {
      if (mounted && generation == _generation) {
        state = AsyncError(error, stackTrace);
      }
      rethrow;
    }
  }
}

class SnackbarController {
  void show(WidgetRef ref, String message) {
    final messengerKey = ref.read(appScaffoldMessengerKeyProvider);
    final messenger = messengerKey.currentState;
    if (messenger == null) {
      return;
    }
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

class ApiException implements Exception {
  const ApiException(this.statusCode, this.body);

  final int statusCode;
  final String body;

  @override
  String toString() => 'HTTP $statusCode: $body';
}

class ResponseDraft {
  const ResponseDraft({
    required this.input,
    this.harnessId,
    this.previousResponseId,
    this.model,
  });

  final String input;
  final String? harnessId;
  final String? previousResponseId;
  final String? model;
}

class UhpService {
  UhpService(this._client);

  final http.Client _client;
  static const Duration timeout = Duration(seconds: 300);

  Future<String> testConnection(ServerConfig server) async {
    final harnesses = await fetchHarnesses(server);
    return '${harnesses.length} harnesses';
  }

  Future<List<Harness>> fetchHarnesses(ServerConfig server) async {
    final abort = Completer<void>();
    final request = http.AbortableRequest(
      'GET',
      buildApiUri(server.baseUrl, '/v1/harnesses'),
      abortTrigger: abort.future,
    );
    final http.Response response;
    try {
      response = await _ProfileClient(
        _client,
        server,
      ).send(request).then(http.Response.fromStream).timeout(timeout);
    } finally {
      abort.complete();
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(response.statusCode, extractErrorBody(response.body));
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const AppError('Unexpected harness response shape.');
    }
    final rawItems = extractHarnessList(decoded);
    return rawItems
        .map((item) => Harness.fromJson(Map<String, dynamic>.from(item as Map)))
        .toList(growable: false);
  }

  StreamingTurn startTurn(ServerConfig server, ResponseDraft draft) =>
      StreamingTurn(_ProfileClient(_client, server), server, draft);

  Future<void> cancelSession(ServerConfig server, String sessionId) =>
      sendSessionCancel(_ProfileClient(_client, server), server, sessionId);
}

Map<String, String> buildAuthHeaders(ServerConfig server) {
  if (!server.hasApiKey) throw const AppError('API key required');
  final headers = <String, String>{
    'Content-Type': 'application/json',
    'Authorization': 'Bearer ${server.apiKey!.trim()}',
  };
  if (server.hasPangolin) {
    headers['P-Access-Token-Id'] = server.accessTokenId!.trim();
    headers['P-Access-Token'] = server.accessToken!.trim();
  }
  return headers;
}

const apiMount = '/api/harness';

Uri buildApiUri(String baseUrl, String path) {
  return Uri.parse('${normalizeBaseUrl(baseUrl)}$apiMount$path');
}

String normalizeBaseUrl(String value) {
  final trimmed = value.trim();
  if (trimmed.endsWith('/')) {
    return trimmed.substring(0, trimmed.length - 1);
  }
  return trimmed;
}

List<dynamic> extractHarnessList(Map<String, dynamic> payload) {
  final data = payload['data'];
  if (data is List<dynamic>) {
    return data;
  }
  final harnesses = payload['harnesses'];
  if (harnesses is List<dynamic>) {
    return harnesses;
  }
  return const <dynamic>[];
}

String extractErrorBody(String body) {
  var message = body;
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) {
      final error = decoded['error'];
      final detail = decoded['detail'];
      if (error is String && error.isNotEmpty) {
        message = error;
      } else if (detail is String && detail.isNotEmpty) {
        message = detail;
      }
    }
  } on FormatException {
    // Non-JSON errors are displayed as a bounded body excerpt.
  }
  return message.length > 280 ? '${message.substring(0, 280)}…' : message;
}

String extractAssistantText(Map<String, dynamic> payload) {
  final output = payload['output'];
  if (output is! List<dynamic>) {
    return '';
  }

  final lines = <String>[];
  for (final item in output) {
    if (item is! Map) {
      continue;
    }
    if ('${item['role'] ?? ''}' != 'assistant') {
      continue;
    }
    final content = item['content'];
    if (content is! List<dynamic>) {
      continue;
    }
    for (final block in content) {
      if (block is! Map) {
        continue;
      }
      final text = block['text'];
      if (text is String && text.isNotEmpty) {
        lines.add(text);
      }
    }
  }
  return lines.join('\n');
}

String extractSessionId(Map<String, dynamic> payload) {
  final metadata = payload['metadata'];
  if (metadata is Map) {
    return '${metadata['session_id'] ?? ''}';
  }
  return '';
}

Map<String, dynamic> buildResponseRequestBody(
  ResponseDraft draft, {
  bool stream = false,
}) {
  final body = <String, dynamic>{'input': draft.input, 'stream': stream};
  final model = draft.model?.trim();
  if (model != null && model.isNotEmpty) body['model'] = model;
  if (draft.harnessId != null && draft.harnessId!.isNotEmpty) {
    body['metadata'] = <String, dynamic>{'harness_id': draft.harnessId};
  }
  if (draft.previousResponseId != null &&
      draft.previousResponseId!.isNotEmpty) {
    body['previous_response_id'] = draft.previousResponseId;
  }
  return body;
}

class UhpApp extends ConsumerWidget {
  const UhpApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'UHP Android',
    scaffoldMessengerKey: ref.watch(appScaffoldMessengerKeyProvider),
    theme: ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorSchemeSeed: Colors.teal,
    ),
    home: const AppShell(),
  );
}

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      final messenger = ref.read(appScaffoldMessengerKeyProvider);
      unawaited(
        ref.read(taskRunnerProvider).interrupt().catchError((Object error) {
          messenger.currentState?.showSnackBar(
            SnackBar(content: Text('$error')),
          );
        }),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // Start loading profiles without rendering any default or stale profiles.
    ref.read(serversProvider);
    final tab = ref.watch(selectedTabProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('UHP Android'),
        actions: [UpdateMenu(service: ref.watch(updateServiceProvider))],
      ),
      body: switch (tab) {
        AppTab.servers => const ServersScreen(),
        AppTab.harnesses => const HarnessesScreen(),
        AppTab.tasks => const TasksScreen(),
        AppTab.history => const HistoryScreen(),
        AppTab.sessions => const SessionsScreen(),
      },
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab.index,
        onDestinationSelected: (index) =>
            ref.read(selectedTabProvider.notifier).state = AppTab.values[index],
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.storage_outlined),
            label: 'Servers',
          ),
          NavigationDestination(
            icon: Icon(Icons.account_tree_outlined),
            label: 'Harnesses',
          ),
          NavigationDestination(
            icon: Icon(Icons.task_alt_outlined),
            label: 'Tasks',
          ),
          NavigationDestination(icon: Icon(Icons.history), label: 'History'),
          NavigationDestination(
            icon: Icon(Icons.forum_outlined),
            label: 'Sessions',
          ),
        ],
      ),
    );
  }
}
