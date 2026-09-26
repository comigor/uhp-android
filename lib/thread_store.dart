part of 'main.dart';

@immutable
class ThreadMessage {
  const ThreadMessage({
    required this.role,
    required this.text,
    this.responseId,
    this.sessionId,
    this.status = TurnStatus.completed,
    this.usage,
    required this.createdAt,
  });

  final String role;
  final String text;
  final String? responseId;
  final String? sessionId;
  final TurnStatus status;
  final TokenUsage? usage;
  final DateTime createdAt;

  factory ThreadMessage.fromJson(Map<String, dynamic> json) {
    final role = json['role'] as String;
    if (role != 'user' && role != 'assistant') {
      throw const FormatException('Invalid thread message role');
    }
    return ThreadMessage(
      role: role,
      text: json['text'] as String,
      responseId: json['responseId'] as String?,
      sessionId: json['sessionId'] as String?,
      status: json['status'] == null
          ? TurnStatus.completed
          : TurnStatus.values.byName(json['status'] as String),
      usage: json['usage'] == null
          ? null
          : TokenUsage.fromJson(json['usage'] as Map<String, dynamic>),
      createdAt: DateTime.parse(json['createdAt'] as String),
    );
  }

  Map<String, dynamic> toJson() => {
    'role': role,
    'text': text,
    'responseId': responseId,
    'sessionId': sessionId,
    'status': status.name,
    'usage': usage?.toJson(),
    'createdAt': createdAt.toUtc().toIso8601String(),
  };
}

@immutable
class ConversationThread {
  ConversationThread({
    required this.id,
    required this.title,
    required this.server,
    required this.harnessId,
    required this.harnessName,
    this.model,
    required this.createdAt,
    required this.updatedAt,
    required List<ThreadMessage> messages,
  }) : messages = List.unmodifiable(messages);

  final String id;
  final String title;
  final ServerConfig server;
  final String harnessId;
  final String harnessName;
  final String? model;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<ThreadMessage> messages;

  String? get lastResponseId {
    for (final message in messages.reversed) {
      if (message.role == 'assistant') return message.responseId;
    }
    return null;
  }

  ThreadSummary get summary => ThreadSummary.fromThread(this);

  factory ConversationThread.start({
    required ServerConfig server,
    required Harness harness,
    required String prompt,
    required ResponseRecord record,
  }) {
    final now = DateTime.now().toUtc();
    final title = String.fromCharCodes(prompt.trim().runes.take(80));
    return ConversationThread(
      id: newLocalId(),
      title: title,
      server: server,
      harnessId: harness.id,
      harnessName: harness.name,
      model: harness.defaultModel.isEmpty || harness.defaultModel == '-'
          ? null
          : harness.defaultModel,
      createdAt: now,
      updatedAt: now,
      messages: [
        ThreadMessage(role: 'user', text: prompt, createdAt: now),
        ThreadMessage(
          role: 'assistant',
          text: record.output,
          responseId: record.responseId.trim().isEmpty
              ? null
              : record.responseId,
          sessionId: record.sessionId,
          status: record.status,
          usage: record.usage,
          createdAt: now,
        ),
      ],
    );
  }

  ConversationThread appendTurn(String prompt, ResponseRecord record) {
    final now = DateTime.now().toUtc();
    return ConversationThread(
      id: id,
      title: title,
      server: server,
      harnessId: harnessId,
      harnessName: harnessName,
      model: model,
      createdAt: createdAt,
      updatedAt: now,
      messages: [
        ...messages,
        ThreadMessage(role: 'user', text: prompt, createdAt: now),
        ThreadMessage(
          role: 'assistant',
          text: record.output,
          responseId: record.responseId.trim().isEmpty
              ? null
              : record.responseId,
          sessionId: record.sessionId,
          status: record.status,
          usage: record.usage,
          createdAt: now,
        ),
      ],
    );
  }

  factory ConversationThread.fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String;
    _validateThreadId(id);
    return ConversationThread(
      id: id,
      title: json['title'] as String,
      server: ServerConfig.fromJson(json['server'] as Map<String, dynamic>),
      harnessId: json['harnessId'] as String,
      harnessName: json['harnessName'] as String,
      model: json['model'] as String?,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      messages: (json['messages'] as List<dynamic>)
          .map((value) => ThreadMessage.fromJson(value as Map<String, dynamic>))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'server': server.toJson(),
    'harnessId': harnessId,
    'harnessName': harnessName,
    'model': model,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'messages': messages.map((message) => message.toJson()).toList(),
  };
}

@immutable
class ThreadSummary {
  const ThreadSummary({
    required this.id,
    required this.title,
    required this.serverId,
    required this.harnessId,
    required this.harnessName,
    this.model,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String title;
  final String serverId;
  final String harnessId;
  final String harnessName;
  final String? model;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory ThreadSummary.fromThread(ConversationThread thread) => ThreadSummary(
    id: thread.id,
    title: thread.title,
    serverId: thread.server.id,
    harnessId: thread.harnessId,
    harnessName: thread.harnessName,
    model: thread.model,
    createdAt: thread.createdAt,
    updatedAt: thread.updatedAt,
  );

  factory ThreadSummary.fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String;
    _validateThreadId(id);
    return ThreadSummary(
      id: id,
      title: json['title'] as String,
      serverId: json['serverId'] as String,
      harnessId: json['harnessId'] as String,
      harnessName: json['harnessName'] as String,
      model: json['model'] as String?,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'serverId': serverId,
    'harnessId': harnessId,
    'harnessName': harnessName,
    'model': model,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };
}

final _threadIdPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$');

void _validateThreadId(String id) {
  if (!_threadIdPattern.hasMatch(id) || id.toLowerCase() == 'index') {
    throw ArgumentError('Invalid thread identifier');
  }
}

class ThreadStore {
  ThreadStore(this.documentsDirectory);

  final Future<Directory> Function() documentsDirectory;
  Future<void> _operations = Future<void>.value();

  // Reads share the queue so they never observe a half-finished local mutation.
  Future<T> _serialize<T>(Future<T> Function() operation) {
    final result = _operations.then((_) => operation());
    _operations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<Directory> _directory() async {
    final documents = await documentsDirectory();
    return Directory('${documents.path}/threads');
  }

  Future<List<ThreadSummary>> loadIndex() => _serialize(() async {
    final directory = await _directory();
    await _recover(directory);
    return _loadIndex(directory);
  });

  Future<ConversationThread?> read(String id) {
    _validateThreadId(id);
    return _serialize(() async => _readThread(await _directory(), id));
  }

  Future<void> save(ConversationThread thread) {
    _validateThreadId(thread.id);
    return _serialize(() async {
      final directory = await _directory();
      await directory.create(recursive: true);
      await _recover(directory);
      // The journal contains no conversation data or credentials. If either
      // commit fails, recovery rebuilds only this entry from its actual file.
      await _atomicWrite(_journal(directory), {'id': thread.id});
      await _atomicWrite(_threadFile(directory, thread.id), thread.toJson());
      await _updateIndex(directory, thread.id, thread.summary);
      await _journal(directory).delete();
    });
  }

  Future<void> delete(String id) {
    _validateThreadId(id);
    return _serialize(() async {
      final directory = await _directory();
      if (!await directory.exists()) return;
      await _recover(directory);
      await _atomicWrite(_journal(directory), {'id': id});
      final file = _threadFile(directory, id);
      if (await file.exists()) await file.delete();
      await _updateIndex(directory, id, null);
      await _journal(directory).delete();
    });
  }

  File _threadFile(Directory directory, String id) =>
      File('${directory.path}/$id.json');

  File _journal(Directory directory) => File('${directory.path}/.pending.json');

  Future<Object?> _readJson(File file, {bool strict = false}) async {
    try {
      if (!await file.exists()) return null;
      return jsonDecode(await file.readAsString());
    } on FileSystemException {
      if (strict) rethrow;
      debugPrint('Unable to read local thread storage.');
      return null;
    } on FormatException {
      debugPrint('Ignoring malformed local thread JSON.');
      return null;
    }
  }

  Future<List<ThreadSummary>> _loadIndex(
    Directory directory, {
    bool strict = false,
  }) async {
    final value = await _readJson(
      File('${directory.path}/index.json'),
      strict: strict,
    );
    if (value == null) return [];
    try {
      final summaries = (value as List<dynamic>)
          .map((row) => ThreadSummary.fromJson(row as Map<String, dynamic>))
          .toList();
      if (summaries.map((summary) => summary.id).toSet().length !=
          summaries.length) {
        throw const FormatException('Duplicate thread identifiers');
      }
      summaries.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return summaries;
    } catch (_) {
      debugPrint('Ignoring malformed local thread index.');
      return [];
    }
  }

  Future<ConversationThread?> _readThread(
    Directory directory,
    String id, {
    bool strict = false,
  }) async {
    final value = await _readJson(_threadFile(directory, id), strict: strict);
    if (value == null) return null;
    try {
      final thread = ConversationThread.fromJson(value as Map<String, dynamic>);
      if (thread.id != id) {
        throw const FormatException('Mismatched thread identifier');
      }
      return thread;
    } catch (_) {
      debugPrint('Ignoring malformed local conversation.');
      return null;
    }
  }

  Future<void> _updateIndex(
    Directory directory,
    String id,
    ThreadSummary? summary,
  ) async {
    final summaries = await _loadIndex(directory, strict: true);
    summaries.removeWhere((entry) => entry.id == id);
    if (summary != null) summaries.add(summary);
    summaries.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    await _atomicWrite(
      File('${directory.path}/index.json'),
      summaries.map((entry) => entry.toJson()).toList(),
    );
  }

  Future<void> _recover(Directory directory) async {
    final journal = _journal(directory);
    final value = await _readJson(journal, strict: true);
    if (value == null) return;
    final String id;
    try {
      id = (value as Map<String, dynamic>)['id'] as String;
      _validateThreadId(id);
    } catch (_) {
      debugPrint('Ignoring malformed local thread journal.');
      return;
    }
    final thread = await _readThread(directory, id, strict: true);
    await _updateIndex(directory, id, thread?.summary);
    await journal.delete();
  }

  Future<void> _atomicWrite(File file, Object value) async {
    final temporary = File('${file.path}.${newLocalId()}.tmp');
    try {
      await temporary.writeAsString(jsonEncode(value), flush: true);
      await temporary.rename(file.path);
    } finally {
      try {
        if (await temporary.exists()) await temporary.delete();
      } on FileSystemException {
        debugPrint('Unable to remove a local thread temporary file.');
      }
    }
  }
}
