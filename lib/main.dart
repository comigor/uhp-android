import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

void main() {
  runApp(const ProviderScope(child: UhpApp()));
}

enum AuthMode { pangolin, console }

enum AppTab { servers, harnesses, tasks }

@immutable
class ServerConfig {
  const ServerConfig({
    required this.name,
    required this.baseUrl,
    required this.authMode,
    this.accessTokenId,
    this.accessToken,
    this.username,
    this.password,
    this.cookie,
  });

  final String name;
  final String baseUrl;
  final AuthMode authMode;
  final String? accessTokenId;
  final String? accessToken;
  final String? username;
  final String? password;
  final String? cookie;

  ServerConfig copyWith({
    String? name,
    String? baseUrl,
    AuthMode? authMode,
    String? accessTokenId,
    String? accessToken,
    String? username,
    String? password,
    String? cookie,
  }) {
    return ServerConfig(
      name: name ?? this.name,
      baseUrl: baseUrl ?? this.baseUrl,
      authMode: authMode ?? this.authMode,
      accessTokenId: accessTokenId ?? this.accessTokenId,
      accessToken: accessToken ?? this.accessToken,
      username: username ?? this.username,
      password: password ?? this.password,
      cookie: cookie ?? this.cookie,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is ServerConfig &&
            runtimeType == other.runtimeType &&
            name == other.name &&
            baseUrl == other.baseUrl &&
            authMode == other.authMode &&
            accessTokenId == other.accessTokenId &&
            accessToken == other.accessToken &&
            username == other.username &&
            password == other.password &&
            cookie == other.cookie;
  }

  @override
  int get hashCode => Object.hash(
    name,
    baseUrl,
    authMode,
    accessTokenId,
    accessToken,
    username,
    password,
    cookie,
  );
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
class ThreadState {
  const ThreadState({this.records = const <ResponseRecord>[]});

  final List<ResponseRecord> records;

  ThreadState append(ResponseRecord record) {
    return ThreadState(records: <ResponseRecord>[...records, record]);
  }

  ResponseRecord? get latestOrNull => records.isEmpty ? null : records.last;
}

@immutable
class AppError implements Exception {
  const AppError(this.message);

  final String message;

  @override
  String toString() => message;
}

class InMemoryServerStore {
  const InMemoryServerStore();

  static const List<ServerConfig> _defaults = <ServerConfig>[
    ServerConfig(
      name: 'HarnessRouter demo',
      baseUrl: 'https://harnessrouter.borges.dev',
      authMode: AuthMode.pangolin,
    ),
  ];

  List<ServerConfig> load() => List<ServerConfig>.unmodifiable(_defaults);
}

final serverStoreProvider = Provider<InMemoryServerStore>((ref) {
  return const InMemoryServerStore();
});

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
    StateNotifierProvider<ServersController, List<ServerConfig>>((ref) {
      return ServersController(ref.watch(serverStoreProvider));
    });

final selectedServerProvider = StateProvider<ServerConfig?>((ref) => null);
final selectedTabProvider = StateProvider<AppTab>((ref) => AppTab.servers);
final selectedHarnessProvider = StateProvider<Harness?>((ref) => null);
final harnessesProvider =
    StateNotifierProvider<HarnessesController, AsyncValue<List<Harness>>>((
      ref,
    ) {
      return HarnessesController(ref);
    });
final threadProvider = StateProvider<ThreadState>((ref) => const ThreadState());
final taskBusyProvider = StateProvider<bool>((ref) => false);

class ServersController extends StateNotifier<List<ServerConfig>> {
  ServersController(InMemoryServerStore store) : super(store.load());

  void upsert(ServerConfig config) {
    final trimmedName = config.name.trim();
    final trimmedBaseUrl = normalizeBaseUrl(config.baseUrl);
    if (trimmedName.isEmpty || trimmedBaseUrl.isEmpty) {
      return;
    }

    final normalized = config.copyWith(
      name: trimmedName,
      baseUrl: trimmedBaseUrl,
    );
    final next = <ServerConfig>[...state];
    final index = next.indexWhere((server) => server.name == normalized.name);
    if (index == -1) {
      next.add(normalized);
    } else {
      next[index] = normalized;
    }
    state = List<ServerConfig>.unmodifiable(next);
  }
}

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
      final harnesses = await _ref
          .read(uhpServiceProvider)
          .fetchHarnesses(server);
      state = AsyncData(harnesses);
    } catch (error, stackTrace) {
      state = AsyncError(error, stackTrace);
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
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedTab = ref.watch(selectedTabProvider);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'UHP Android',
      scaffoldMessengerKey: ref.watch(appScaffoldMessengerKeyProvider),
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.teal,
      ),
      home: Scaffold(
        appBar: AppBar(title: const Text('UHP Android')),
        body: IndexedStack(
          index: selectedTab.index,
          children: const <Widget>[
            ServersScreen(),
            HarnessesScreen(),
            TasksScreen(),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: selectedTab.index,
          onDestinationSelected: (index) {
            ref.read(selectedTabProvider.notifier).state = AppTab.values[index];
          },
          destinations: const <NavigationDestination>[
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
          ],
        ),
      ),
    );
  }
}

class ServersScreen extends ConsumerStatefulWidget {
  const ServersScreen({super.key});

  @override
  ConsumerState<ServersScreen> createState() => _ServersScreenState();
}

class _ServersScreenState extends ConsumerState<ServersScreen> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _urlController = TextEditingController(
    text: 'https://harnessrouter.borges.dev',
  );
  final TextEditingController _tokenIdController = TextEditingController();
  final TextEditingController _tokenController = TextEditingController();
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _testing = false;
  AuthMode _mode = AuthMode.pangolin;

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    _tokenIdController.dispose();
    _tokenController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final servers = ref.watch(serversProvider);
    final selectedServer = ref.watch(selectedServerProvider);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Text(
          'In-memory profiles only. Process death clears history and server edits.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        const Text(
          'Saved servers',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        if (servers.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('No saved servers yet.'),
            ),
          )
        else
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: servers.length,
            itemBuilder: (context, index) {
              final server = servers[index];
              final isSelected = selectedServer == server;
              return Card(
                child: ListTile(
                  title: Text(server.name),
                  subtitle: Text('${server.baseUrl}\n${server.authMode.name}'),
                  isThreeLine: true,
                  trailing: Icon(
                    isSelected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                  ),
                  onTap: () {
                    ref.read(selectedServerProvider.notifier).state = server;
                  },
                ),
              );
            },
          ),
        const SizedBox(height: 16),
        const Text(
          'Add or update server',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<AuthMode>(
          initialValue: _mode,
          decoration: const InputDecoration(labelText: 'Auth mode'),
          items: const <DropdownMenuItem<AuthMode>>[
            DropdownMenuItem(
              value: AuthMode.pangolin,
              child: Text('Pangolin machine token'),
            ),
            DropdownMenuItem(
              value: AuthMode.console,
              child: Text('Console login cookie'),
            ),
          ],
          onChanged: (value) {
            setState(() {
              _mode = value ?? AuthMode.pangolin;
            });
          },
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _nameController,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _urlController,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(labelText: 'Base URL'),
        ),
        const SizedBox(height: 8),
        if (_mode == AuthMode.pangolin) ...<Widget>[
          TextField(
            controller: _tokenIdController,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(labelText: 'P-Access-Token-Id'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _tokenController,
            decoration: const InputDecoration(labelText: 'P-Access-Token'),
          ),
        ] else ...<Widget>[
          TextField(
            controller: _usernameController,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(labelText: 'Username'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _passwordController,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Password'),
          ),
        ],
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: <Widget>[
            FilledButton(
              onPressed: _saveServer,
              child: const Text('Save server'),
            ),
            OutlinedButton(
              onPressed: selectedServer == null || _testing
                  ? null
                  : _testConnection,
              child: Text(_testing ? 'Testing…' : 'Test connection'),
            ),
          ],
        ),
      ],
    );
  }

  void _saveServer() {
    final normalizedName = _nameController.text.trim();
    if (normalizedName.isEmpty) {
      ref.read(snackbarControllerProvider).show(ref, 'Name is required.');
      return;
    }

    final normalizedBaseUrl = normalizeBaseUrl(_urlController.text);
    if (normalizedBaseUrl.isEmpty) {
      ref.read(snackbarControllerProvider).show(ref, 'Base URL is required.');
      return;
    }

    final config = ServerConfig(
      name: normalizedName,
      baseUrl: normalizedBaseUrl,
      authMode: _mode,
      accessTokenId: _emptyToNull(_tokenIdController.text),
      accessToken: _emptyToNull(_tokenController.text),
      username: _emptyToNull(_usernameController.text),
      password: _emptyToNull(_passwordController.text),
    );
    ref.read(serversProvider.notifier).upsert(config);
    ref.read(selectedServerProvider.notifier).state = config;
    ref.read(snackbarControllerProvider).show(ref, 'Saved $normalizedName.');
  }

  Future<void> _testConnection() async {
    final selectedServer = ref.read(selectedServerProvider);
    if (selectedServer == null) {
      return;
    }

    setState(() {
      _testing = true;
    });
    try {
      final service = ref.read(uhpServiceProvider);
      final authenticated = await service.login(selectedServer);
      if (authenticated != selectedServer) {
        ref.read(serversProvider.notifier).upsert(authenticated);
        ref.read(selectedServerProvider.notifier).state = authenticated;
      }
      final message = await service.testConnection(authenticated);
      if (mounted) {
        ref.read(snackbarControllerProvider).show(ref, message);
      }
    } catch (error) {
      if (mounted) {
        ref.read(snackbarControllerProvider).show(ref, '$error');
      }
    } finally {
      if (mounted) {
        setState(() {
          _testing = false;
        });
      }
    }
  }

  String? _emptyToNull(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

class HarnessesScreen extends ConsumerWidget {
  const HarnessesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final harnesses = ref.watch(harnessesProvider);
    return RefreshIndicator(
      onRefresh: () => _refreshHarnesses(ref),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          const Text(
            'Harnesses',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () => _refreshHarnesses(ref),
            child: const Text('Load harnesses'),
          ),
          const SizedBox(height: 12),
          harnesses.when(
            data: (items) {
              if (items.isEmpty) {
                return const Card(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('No harnesses loaded yet.'),
                  ),
                );
              }
              return ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final harness = items[index];
                  return Card(
                    child: ListTile(
                      title: Text(harness.name),
                      subtitle: Text(
                        'Base label: ${harness.baseLabel}\nDefault model: ${harness.defaultModel}',
                      ),
                      isThreeLine: true,
                      onTap: () {
                        ref.read(selectedHarnessProvider.notifier).state =
                            harness;
                        ref.read(selectedTabProvider.notifier).state =
                            AppTab.tasks;
                      },
                    ),
                  );
                },
              );
            },
            loading: () => const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (error, _) => Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text('$error'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _refreshHarnesses(WidgetRef ref) async {
    try {
      await ref.read(harnessesProvider.notifier).refresh();
    } catch (error) {
      ref.read(snackbarControllerProvider).show(ref, '$error');
    }
  }
}

class TasksScreen extends ConsumerStatefulWidget {
  const TasksScreen({super.key});

  @override
  ConsumerState<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends ConsumerState<TasksScreen> {
  final TextEditingController _promptController = TextEditingController();

  @override
  void dispose() {
    _promptController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selectedHarness = ref.watch(selectedHarnessProvider);
    final thread = ref.watch(threadProvider);
    final busy = ref.watch(taskBusyProvider);
    final latest = thread.latestOrNull;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        const Text(
          'Tasks',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('Selected harness: ${selectedHarness?.name ?? 'none'}'),
                const SizedBox(height: 4),
                Text(
                  'Thread length: ${thread.records.length}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _promptController,
          minLines: 3,
          maxLines: 8,
          decoration: const InputDecoration(labelText: 'Prompt'),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: <Widget>[
            FilledButton(
              onPressed: busy ? null : _runTask,
              child: Text(busy ? 'Working…' : 'Run task'),
            ),
            OutlinedButton(
              onPressed: busy || latest == null
                  ? null
                  : () => _continueThread(latest),
              child: const Text('Continue latest'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (thread.records.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('No task history yet.'),
            ),
          )
        else
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: thread.records.length,
            itemBuilder: (context, index) {
              final record = thread.records[index];
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Prompt',
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                      const SizedBox(height: 4),
                      Text(record.prompt),
                      const Divider(height: 24),
                      Text(
                        'Assistant output',
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                      const SizedBox(height: 4),
                      SelectableText(
                        record.output.isEmpty
                            ? '(empty output)'
                            : record.output,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'response_id=${record.responseId}\nsession_id=${record.sessionId.isEmpty ? '-' : record.sessionId}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: busy
                              ? null
                              : () => _continueThread(record),
                          child: const Text('Continue'),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
      ],
    );
  }

  Future<void> _runTask() async {
    final prompt = _promptController.text.trim();
    if (prompt.isEmpty) {
      ref.read(snackbarControllerProvider).show(ref, 'Enter a prompt first.');
      return;
    }

    final server = ref.read(selectedServerProvider);
    final harness = ref.read(selectedHarnessProvider);
    if (server == null) {
      ref.read(snackbarControllerProvider).show(ref, 'Select a server first.');
      return;
    }
    if (harness == null) {
      ref.read(snackbarControllerProvider).show(ref, 'Select a harness first.');
      return;
    }

    await _submitDraft(
      draft: ResponseDraft(input: prompt, harnessId: harness.id),
      clearPrompt: true,
    );
  }

  Future<void> _continueThread(ResponseRecord record) async {
    final continuation = _promptController.text.trim();
    if (continuation.isEmpty) {
      ref
          .read(snackbarControllerProvider)
          .show(ref, 'Enter continuation input first.');
      return;
    }

    final harness = ref.read(selectedHarnessProvider);
    await _submitDraft(
      draft: ResponseDraft(
        input: continuation,
        harnessId: harness?.id,
        previousResponseId: record.responseId,
      ),
      clearPrompt: true,
    );
  }

  Future<void> _submitDraft({
    required ResponseDraft draft,
    required bool clearPrompt,
  }) async {
    final server = ref.read(selectedServerProvider);
    if (server == null) {
      return;
    }

    ref.read(taskBusyProvider.notifier).state = true;
    try {
      final service = ref.read(uhpServiceProvider);
      final authedServer = await service.login(server);
      if (authedServer != server) {
        ref.read(serversProvider.notifier).upsert(authedServer);
        ref.read(selectedServerProvider.notifier).state = authedServer;
      }
      final record = await service.createResponse(authedServer, draft);
      final currentThread = ref.read(threadProvider);
      ref.read(threadProvider.notifier).state = currentThread.append(record);
      if (clearPrompt) {
        _promptController.clear();
      }
    } catch (error) {
      ref.read(snackbarControllerProvider).show(ref, '$error');
    } finally {
      ref.read(taskBusyProvider.notifier).state = false;
    }
  }
}
