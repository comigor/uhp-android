import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

void main() {
  runApp(const ProviderScope(child: UhpApp()));
}

enum AuthMode { pangolin, console }

enum AppTab { servers, harnesses, tasks }

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

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
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

  @override
  int get hashCode => Object.hash(name, baseUrl, authMode, accessTokenId, accessToken, username, password, cookie);
}

class Harness {
  const Harness({required this.id, required this.name, this.baseLabel, this.defaultModel});

  final String id;
  final String name;
  final String? baseLabel;
  final String? defaultModel;

  factory Harness.fromJson(Map<String, dynamic> json) {
    return Harness(
      id: '${json['id'] ?? json['harness_id'] ?? json['name'] ?? ''}',
      name: '${json['name'] ?? json['label'] ?? json['id'] ?? ''}',
      baseLabel: json['base_label'] as String?,
      defaultModel: json['default_model'] as String?,
    );
  }
}

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
  final String? sessionId;
}

class ThreadState {
  const ThreadState({this.records = const []});

  final List<ResponseRecord> records;

  ThreadState append(ResponseRecord record) => ThreadState(records: [...records, record]);
}

class InMemoryServerStore {
  const InMemoryServerStore();

  static final List<ServerConfig> _defaults = [
    const ServerConfig(
      name: 'HarnessRouter demo',
      baseUrl: 'https://harnessrouter.borges.dev',
      authMode: AuthMode.pangolin,
    ),
  ];

  List<ServerConfig> load() => List<ServerConfig>.unmodifiable(_defaults);
}

final serverStoreProvider = Provider<InMemoryServerStore>((ref) => const InMemoryServerStore());
final serversProvider = StateNotifierProvider<ServersController, List<ServerConfig>>(
  (ref) => ServersController(),
);
final selectedServerProvider = StateProvider<ServerConfig?>((ref) => null);
final selectedTabProvider = StateProvider<AppTab>((ref) => AppTab.servers);
final harnessesProvider = StateNotifierProvider<HarnessesController, AsyncValue<List<Harness>>>((ref) {
  return HarnessesController(ref);
});
final selectedHarnessProvider = StateProvider<Harness?>((ref) => null);
final taskBusyProvider = StateProvider<bool>((ref) => false);
final threadProvider = StateProvider<ThreadState>((ref) => const ThreadState());

class ServersController extends StateNotifier<List<ServerConfig>> {
  ServersController() : super(const InMemoryServerStore().load());

  void upsert(ServerConfig config) {
    final next = [...state];
    final index = next.indexWhere((server) => server.name == config.name);
    if (index == -1) {
      next.add(config);
    } else {
      next[index] = config;
    }
    state = List<ServerConfig>.unmodifiable(next);
  }
}

class HarnessesController extends StateNotifier<AsyncValue<List<Harness>>> {
  HarnessesController(this._ref) : super(const AsyncData(<Harness>[]));

  final Ref _ref;

  Future<void> refresh() async {
    final server = _ref.read(selectedServerProvider);
    if (server == null) return;
    state = const AsyncLoading();
    try {
      final client = ApiClient(server);
      final list = await client.fetchHarnesses();
      state = AsyncData(list);
    } catch (error, stackTrace) {
      state = AsyncError(error, stackTrace);
      rethrow;
    }
  }
}

class ApiException implements Exception {
  const ApiException(this.statusCode, this.body);

  final int statusCode;
  final String body;

  @override
  String toString() => 'HTTP $statusCode: $body';
}

class ApiClient {
  ApiClient(this.server, {http.Client? client}) : _client = client ?? http.Client();

  final ServerConfig server;
  final http.Client _client;
  static const _timeout = Duration(seconds: 300);

  Map<String, String> _headers() {
    final headers = <String, String>{'Content-Type': 'application/json'};
    if (server.authMode == AuthMode.pangolin) {
      if (server.accessTokenId != null) headers['P-Access-Token-Id'] = server.accessTokenId!;
      if (server.accessToken != null) headers['P-Access-Token'] = server.accessToken!;
    } else if (server.cookie != null && server.cookie!.isNotEmpty) {
      headers['Cookie'] = server.cookie!;
    }
    return headers;
  }

  Uri _uri(String path) => Uri.parse('${server.baseUrl}$path');

  Future<List<Harness>> fetchHarnesses() async {
    final response = await _client.get(_uri('/api/harness/v1/harnesses'), headers: _headers()).timeout(_timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(response.statusCode, extractErrorBody(response.body));
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final items = (data['data'] as List<dynamic>? ?? data['harnesses'] as List<dynamic>? ?? const []);
    return items.map((item) => Harness.fromJson(Map<String, dynamic>.from(item as Map))).toList(growable: false);
  }

  Future<String> testConnection() async => '${(await fetchHarnesses()).length} harnesses';

  Future<ResponseRecord> createResponse({
    required String input,
    String? previousResponseId,
    String? harnessId,
  }) async {
    final payload = <String, dynamic>{'input': input, 'stream': false};
    if (harnessId != null) {
      payload['metadata'] = {'harness_id': harnessId};
    }
    if (previousResponseId != null) {
      payload['previous_response_id'] = previousResponseId;
    }
    final response = await _client.post(
      _uri('/api/harness/v1/responses'),
      headers: _headers(),
      body: jsonEncode(payload),
    ).timeout(_timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(response.statusCode, extractErrorBody(response.body));
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return ResponseRecord(
      prompt: input,
      output: extractAssistantText(data),
      responseId: '${data['id'] ?? ''}',
      sessionId: data['metadata'] is Map ? '${(data['metadata'] as Map)['session_id'] ?? ''}' : null,
    );
  }
}

String extractErrorBody(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) {
      return '${decoded['error'] ?? decoded['detail'] ?? body}';
    }
  } catch (_) {}
  return body;
}

String extractAssistantText(Map<String, dynamic> data) {
  final outputs = data['output'] as List<dynamic>? ?? const [];
  final buffer = StringBuffer();
  for (final item in outputs) {
    if (item is! Map) continue;
    if ('${item['role'] ?? ''}' != 'assistant') continue;
    final content = item['content'] as List<dynamic>? ?? const [];
    for (final block in content) {
      if (block is Map && block['text'] != null) {
        if (buffer.isNotEmpty) buffer.write('\n');
        buffer.write(block['text']);
      }
    }
  }
  return buffer.toString();
}

Map<String, dynamic> buildContinuationBody({required String input, required String previousResponseId, String? harnessId}) {
  final body = <String, dynamic>{'input': input, 'previous_response_id': previousResponseId};
  if (harnessId != null) body['metadata'] = {'harness_id': harnessId};
  return body;
}

class UhpApp extends ConsumerWidget {
  const UhpApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tab = ref.watch(selectedTabProvider);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'UHP Android',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.teal,
      ),
      home: Scaffold(
        appBar: AppBar(title: const Text('UHP Android')),
        body: IndexedStack(
          index: tab.index,
          children: const [ServersScreen(), HarnessesScreen(), TasksScreen()],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: tab.index,
          onDestinationSelected: (index) => ref.read(selectedTabProvider.notifier).state = AppTab.values[index],
          destinations: const [
            NavigationDestination(icon: Icon(Icons.storage_outlined), label: 'Servers'),
            NavigationDestination(icon: Icon(Icons.account_tree_outlined), label: 'Harnesses'),
            NavigationDestination(icon: Icon(Icons.task_alt_outlined), label: 'Tasks'),
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
  final _name = TextEditingController();
  final _url = TextEditingController();
  final _tokenId = TextEditingController();
  final _token = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  AuthMode _mode = AuthMode.pangolin;

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _tokenId.dispose();
    _token.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final servers = ref.watch(serversProvider);
    final selected = ref.watch(selectedServerProvider);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('Servers', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        ...servers.map((server) => Card(
          child: ListTile(
            title: Text(server.name),
            subtitle: Text('${server.baseUrl}\n${server.authMode.name}'),
            isThreeLine: true,
            trailing: IconButton(
              icon: Icon(selected == server ? Icons.radio_button_checked : Icons.radio_button_off),
              onPressed: () => ref.read(selectedServerProvider.notifier).state = server,
            ),
            onTap: () => ref.read(selectedServerProvider.notifier).state = server,
          ),
        )),
        const SizedBox(height: 12),
        DropdownButtonFormField<AuthMode>(
          initialValue: _mode,
          items: const [
            DropdownMenuItem(value: AuthMode.pangolin, child: Text('Pangolin machine token')),
            DropdownMenuItem(value: AuthMode.console, child: Text('Console login cookie')),
          ],
          onChanged: (value) => setState(() => _mode = value ?? AuthMode.pangolin),
          decoration: const InputDecoration(labelText: 'Auth mode'),
        ),
        TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name')),
        TextField(controller: _url, decoration: const InputDecoration(labelText: 'Base URL')),
        if (_mode == AuthMode.pangolin) ...[
          TextField(controller: _tokenId, decoration: const InputDecoration(labelText: 'P-Access-Token-Id')),
          TextField(controller: _token, decoration: const InputDecoration(labelText: 'P-Access-Token')),
        ] else ...[
          TextField(controller: _username, decoration: const InputDecoration(labelText: 'Username')),
          TextField(controller: _password, decoration: const InputDecoration(labelText: 'Password'), obscureText: true),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            FilledButton(
              onPressed: () {
                ref.read(serversProvider.notifier).upsert(ServerConfig(
                  name: _name.text.trim(),
                  baseUrl: _url.text.trim(),
                  authMode: _mode,
                  accessTokenId: _tokenId.text.trim().isEmpty ? null : _tokenId.text.trim(),
                  accessToken: _token.text.trim().isEmpty ? null : _token.text.trim(),
                  username: _username.text.trim().isEmpty ? null : _username.text.trim(),
                  password: _password.text.isEmpty ? null : _password.text,
                ));
              },
              child: const Text('Save server'),
            ),
            const SizedBox(width: 12),
            OutlinedButton(
              onPressed: selected == null ? null : () async {
                try {
                  final message = await ApiClient(selected).testConnection();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
                  }
                } catch (error) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error')));
                  }
                }
              },
              child: const Text('Test connection'),
            ),
          ],
        ),
      ],
    );
  }
}

class HarnessesScreen extends ConsumerWidget {
  const HarnessesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final harnesses = ref.watch(harnessesProvider);
    return RefreshIndicator(
      onRefresh: () => ref.read(harnessesProvider.notifier).refresh(),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Harnesses', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () async {
              try {
                await ref.read(harnessesProvider.notifier).refresh();
              } catch (error) {
                if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error')));
              }
            },
            child: const Text('Load harnesses'),
          ),
          const SizedBox(height: 12),
          harnesses.when(
            data: (items) => ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: items.length,
              itemBuilder: (context, index) {
                final harness = items[index];
                return Card(
                  child: ListTile(
                    title: Text(harness.name),
                    subtitle: Text('${harness.baseLabel ?? '-'}\n${harness.defaultModel ?? '-'}'),
                    isThreeLine: true,
                    onTap: () {
                      ref.read(selectedHarnessProvider.notifier).state = harness;
                      ref.read(selectedTabProvider.notifier).state = AppTab.tasks;
                    },
                  ),
                );
              },
            ),
            loading: () => const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (error, _) => Text('$error'),
          ),
        ],
      ),
    );
  }
}

class TasksScreen extends ConsumerStatefulWidget {
  const TasksScreen({super.key});

  @override
  ConsumerState<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends ConsumerState<TasksScreen> {
  final _promptController = TextEditingController();

  @override
  void dispose() {
    _promptController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final harness = ref.watch(selectedHarnessProvider);
    final busy = ref.watch(taskBusyProvider);
    final thread = ref.watch(threadProvider);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('Tasks', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        Text('Selected harness: ${harness?.name ?? 'none'}'),
        TextField(controller: _promptController, decoration: const InputDecoration(labelText: 'Prompt')),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: busy ? null : () async {
            final server = ref.read(selectedServerProvider);
            final selectedHarness = ref.read(selectedHarnessProvider);
            if (server == null || selectedHarness == null) return;
            ref.read(taskBusyProvider.notifier).state = true;
            try {
              final record = await ApiClient(server).createResponse(
                input: _promptController.text,
                harnessId: selectedHarness.id,
              );
              ref.read(threadProvider.notifier).state = thread.append(record);
            } catch (error) {
              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error')));
            } finally {
              ref.read(taskBusyProvider.notifier).state = false;
            }
          },
          child: Text(busy ? 'Working…' : 'Run'),
        ),
        const SizedBox(height: 12),
        ...thread.records.map((record) => Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Prompt: ${record.prompt}'),
                const SizedBox(height: 8),
                Text(record.output),
                const SizedBox(height: 8),
                Text('response=${record.responseId} session=${record.sessionId ?? '-'}', style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () async {
                      final server = ref.read(selectedServerProvider);
                      final selectedHarness = ref.read(selectedHarnessProvider);
                      if (server == null || selectedHarness == null) return;
                      ref.read(taskBusyProvider.notifier).state = true;
                      try {
                        final continuation = await ApiClient(server).createResponse(
                          input: record.output,
                          previousResponseId: record.responseId,
                          harnessId: selectedHarness.id,
                        );
                        ref.read(threadProvider.notifier).state = thread.append(continuation);
                      } catch (error) {
                        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error')));
                      } finally {
                        ref.read(taskBusyProvider.notifier).state = false;
                      }
                    },
                    child: const Text('Continue'),
                  ),
                ),
              ],
            ),
          ),
        )),
      ],
    );
  }
}
