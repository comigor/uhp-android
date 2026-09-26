import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'server_store.dart';
part 'thread_store.dart';
part 'screens.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: UhpApp()));
}

enum AuthMode { pangolin, console }

enum AppTab { servers, harnesses, tasks, history }

@immutable
class ServerConfig {
  const ServerConfig({
    this.id = '',
    required this.name,
    required this.baseUrl,
    required this.authMode,
    this.accessTokenId,
    this.accessToken,
    this.username,
    this.password,
    this.cookie,
    this.testResult,
  });

  final String id;
  final String name;
  final String baseUrl;
  final AuthMode authMode;
  final String? accessTokenId;
  final String? accessToken;
  final String? username;
  final String? password;
  final String? cookie;
  final String? testResult;

  ServerConfig copyWith({
    String? name,
    String? baseUrl,
    String? cookie,
    String? testResult,
  }) => ServerConfig(
    id: id,
    name: name ?? this.name,
    baseUrl: baseUrl ?? this.baseUrl,
    authMode: authMode,
    accessTokenId: accessTokenId,
    accessToken: accessToken,
    username: username,
    password: password,
    cookie: cookie ?? this.cookie,
    testResult: testResult ?? this.testResult,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'baseUrl': baseUrl,
    'authMode': authMode.name,
    'accessTokenId': accessTokenId,
    'accessToken': accessToken,
    'username': username,
    'password': password,
    'cookie': cookie,
    'testResult': testResult,
  };

  factory ServerConfig.fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String;
    if (id.isEmpty) throw const FormatException('Missing server ID');
    return ServerConfig(
      id: id,
      name: json['name'] as String,
      baseUrl: json['baseUrl'] as String,
      authMode: AuthMode.values.byName(json['authMode'] as String),
      accessTokenId: json['accessTokenId'] as String?,
      accessToken: json['accessToken'] as String?,
      username: json['username'] as String?,
      password: json['password'] as String?,
      cookie: json['cookie'] as String?,
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
  });

  final String prompt;
  final String output;
  final String responseId;
  final String sessionId;
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

  Future<void> refresh() async {
    final server = _ref.read(selectedServerProvider);
    if (server == null) {
      throw const AppError('Select a server first.');
    }
    state = const AsyncLoading();
    try {
      final service = _ref.read(uhpServiceProvider);
      final authenticated =
          server.authMode == AuthMode.console &&
              (server.cookie?.isEmpty ?? true)
          ? await service.login(server)
          : server;
      if (!mounted) return;
      if (authenticated.cookie != server.cookie) {
        await _ref
            .read(serversProvider.notifier)
            .updateCookie(server, authenticated.cookie!);
      }
      final harnesses = await service.fetchHarnesses(authenticated);
      if (mounted) state = AsyncData(harnesses);
    } catch (error, stackTrace) {
      if (mounted) state = AsyncError(error, stackTrace);
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
  });

  final String input;
  final String? harnessId;
  final String? previousResponseId;
}

class UhpService {
  const UhpService(this._client);

  final http.Client _client;
  static const Duration timeout = Duration(seconds: 300);

  Future<ServerConfig> login(ServerConfig server) async {
    if (server.authMode != AuthMode.console) {
      return server;
    }
    final username = server.username?.trim() ?? '';
    final password = server.password ?? '';
    if (username.isEmpty || password.isEmpty) {
      throw const AppError('Console login requires username and password.');
    }

    final response = await _client
        .post(
          buildApiUri(server.baseUrl, '/api/selfhost/login'),
          headers: const <String, String>{'Content-Type': 'application/json'},
          body: jsonEncode(<String, dynamic>{
            'username': username,
            'password': password,
          }),
        )
        .timeout(timeout);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(response.statusCode, extractErrorBody(response.body));
    }

    final cookie = extractCookie(response.headers);
    if (cookie.isEmpty) {
      throw const AppError('Console login succeeded without Set-Cookie.');
    }
    return server.copyWith(cookie: cookie);
  }

  Future<String> testConnection(ServerConfig server) async {
    final authedServer = await _ensureAuthenticated(server);
    final harnesses = await fetchHarnesses(authedServer);
    return '${harnesses.length} harnesses';
  }

  Future<List<Harness>> fetchHarnesses(ServerConfig server) async {
    final response = await _client
        .get(
          buildApiUri(server.baseUrl, '/api/harness/v1/harnesses'),
          headers: buildAuthHeaders(server),
        )
        .timeout(timeout);

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

  Future<ResponseRecord> createResponse(
    ServerConfig server,
    ResponseDraft draft,
  ) async {
    final response = await _client
        .post(
          buildApiUri(server.baseUrl, '/api/harness/v1/responses'),
          headers: buildAuthHeaders(server),
          body: jsonEncode(buildResponseRequestBody(draft)),
        )
        .timeout(timeout);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(response.statusCode, extractErrorBody(response.body));
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const AppError('Unexpected response payload.');
    }
    return ResponseRecord(
      prompt: draft.input,
      output: extractAssistantText(decoded),
      responseId: '${decoded['id'] ?? ''}',
      sessionId: extractSessionId(decoded),
    );
  }

  Future<ServerConfig> _ensureAuthenticated(ServerConfig server) async {
    if (server.authMode == AuthMode.console &&
        (server.cookie == null || server.cookie!.isEmpty)) {
      return login(server);
    }
    return server;
  }
}

Map<String, String> buildAuthHeaders(ServerConfig server) {
  final headers = <String, String>{'Content-Type': 'application/json'};
  switch (server.authMode) {
    case AuthMode.pangolin:
      final tokenId = server.accessTokenId?.trim() ?? '';
      final token = server.accessToken?.trim() ?? '';
      if (tokenId.isNotEmpty) {
        headers['P-Access-Token-Id'] = tokenId;
      }
      if (token.isNotEmpty) {
        headers['P-Access-Token'] = token;
      }
      break;
    case AuthMode.console:
      final cookie = server.cookie?.trim() ?? '';
      if (cookie.isNotEmpty) {
        headers['Cookie'] = cookie;
      }
      break;
  }
  return headers;
}

Uri buildApiUri(String baseUrl, String path) {
  return Uri.parse('${normalizeBaseUrl(baseUrl)}$path');
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
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) {
      final error = decoded['error'];
      if (error is String && error.isNotEmpty) {
        return error;
      }
      final detail = decoded['detail'];
      if (detail is String && detail.isNotEmpty) {
        return detail;
      }
    }
  } catch (_) {
    return body.length > 280 ? '${body.substring(0, 280)}…' : body;
  }
  return body.length > 280 ? '${body.substring(0, 280)}…' : body;
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

String extractCookie(Map<String, String> headers) {
  final raw = headers['set-cookie'] ?? headers['Set-Cookie'];
  if (raw == null || raw.isEmpty) {
    return '';
  }
  final firstCookie = raw.split(',').first;
  return firstCookie.split(';').first.trim();
}

Map<String, dynamic> buildResponseRequestBody(ResponseDraft draft) {
  final body = <String, dynamic>{'input': draft.input, 'stream': false};
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

class AppShell extends ConsumerWidget {
  const AppShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Start loading profiles without rendering any default or stale profiles.
    ref.read(serversProvider);
    final tab = ref.watch(selectedTabProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('UHP Android')),
      body: switch (tab) {
        AppTab.servers => const ServersScreen(),
        AppTab.harnesses => const HarnessesScreen(),
        AppTab.tasks => const TasksScreen(),
        AppTab.history => const HistoryScreen(),
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
        ],
      ),
    );
  }
}
