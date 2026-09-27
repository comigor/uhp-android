part of 'main.dart';

@immutable
class ServerSession {
  const ServerSession({
    required this.id,
    this.title = '',
    this.model = '',
    this.harnessId = '',
    this.status = '',
    this.lastResponseId,
    this.updatedAt,
  });

  final String id;
  final String title;
  final String model;
  final String harnessId;
  final String status;
  final String? lastResponseId;
  final DateTime? updatedAt;

  bool get isRunning =>
      const {'running', 'in_progress'}.contains(status.toLowerCase());

  factory ServerSession.fromJson(Map<String, dynamic> json) {
    final metadata = json['metadata'];
    return ServerSession(
      id:
          _serverString(
            json['session_id'] ?? json['sessionId'] ?? json['id'],
          ) ??
          '',
      title: _serverString(json['title'] ?? json['name']) ?? '',
      model: _serverString(json['model']) ?? '',
      harnessId:
          _serverString(
            json['harness_id'] ??
                json['harnessId'] ??
                (metadata is Map
                    ? metadata['harness_id'] ?? metadata['harnessId']
                    : null),
          ) ??
          '',
      status: _serverString(json['status']) ?? '',
      lastResponseId: _serverString(
        json['last_response_id'] ?? json['lastResponseId'],
      ),
      updatedAt: DateTime.tryParse(
        _serverString(
              json['updated_at'] ??
                  json['updatedAt'] ??
                  json['created_at'] ??
                  json['createdAt'],
            ) ??
            '',
      ),
    );
  }
}

@immutable
class SessionPage {
  const SessionPage({required this.sessions, this.cursor});

  final List<ServerSession> sessions;
  final String? cursor;
}

@immutable
class SessionTurn {
  const SessionTurn({required this.role, required this.text});

  final String role;
  final String text;
}

String? _serverString(Object? value) => value is String ? value : null;

List<dynamic> _serverList(Object? payload, List<String> keys) {
  if (payload is List) return payload;
  if (payload is Map) {
    for (final key in keys) {
      if (payload[key] is List) return payload[key] as List;
    }
    if (payload['data'] is Map) return _serverList(payload['data'], keys);
  }
  return const [];
}

String _serverText(Object? value) {
  if (value is String) return value;
  if (value is List) {
    return value.map(_serverText).where((text) => text.isNotEmpty).join('\n');
  }
  if (value is Map) {
    return _serverText(value['text'] ?? value['content'] ?? value['message']);
  }
  return '';
}

Map<String, dynamic> _serverObject(Object? payload, String key) {
  if (payload is Map<String, dynamic>) {
    if (payload.containsKey('id') ||
        (key == 'harness' &&
            payload.containsKey('name') &&
            payload.containsKey('base')) ||
        (key == 'session' &&
            (payload.containsKey('session_id') ||
                payload.containsKey('sessionId')))) {
      return payload;
    }
    final nested = payload[key] ?? payload['data'];
    if (nested is Map<String, dynamic>) return nested;
    return payload;
  }
  throw const AppError('Unexpected server response shape.');
}

extension ServerApi on UhpService {
  Future<Object?> _serverJson(
    ServerConfig server,
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, dynamic>? body,
  }) async {
    final abort = Completer<void>();
    final uri = buildApiUri(server.baseUrl, path);
    final request = http.AbortableRequest(
      method,
      query == null ? uri : uri.replace(queryParameters: query),
      abortTrigger: abort.future,
    );
    if (body != null) request.body = jsonEncode(body);
    final http.Response response;
    try {
      response = await _ProfileClient(_client, server)
          .send(request)
          .then(http.Response.fromStream)
          .timeout(UhpService.timeout);
    } finally {
      abort.complete();
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(response.statusCode, extractErrorBody(response.body));
    }
    return jsonDecode(response.body);
  }

  Future<SessionPage> fetchSessions(
    ServerConfig server, {
    String? cursor,
    String? harnessId,
  }) async {
    final payload = await _serverJson(
      server,
      'GET',
      '/v1/sessions',
      query: {
        'limit': '20',
        'cursor': ?cursor,
        if (harnessId != null && harnessId.isNotEmpty) 'harness': harnessId,
      },
    );
    final sessions = _serverList(payload, const ['sessions', 'data'])
        .whereType<Map<String, dynamic>>()
        .map(ServerSession.fromJson)
        .where((session) => session.id.isNotEmpty)
        .toList(growable: false);
    String? nextCursor;
    if (payload is Map) {
      final data = payload['data'];
      final pagination = payload['pagination'];
      nextCursor = _serverString(
        payload['next_cursor'] ??
            payload['nextCursor'] ??
            payload['cursor'] ??
            (data is Map
                ? data['next_cursor'] ?? data['nextCursor'] ?? data['cursor']
                : null) ??
            (pagination is Map
                ? pagination['next_cursor'] ??
                      pagination['nextCursor'] ??
                      pagination['cursor']
                : null),
      );
    }
    return SessionPage(sessions: sessions, cursor: nextCursor);
  }

  Future<ServerSession> fetchSession(ServerConfig server, String sid) async {
    final payload = await _serverJson(
      server,
      'GET',
      '/v1/sessions/${Uri.encodeComponent(sid)}',
    );
    final session = ServerSession.fromJson(_serverObject(payload, 'session'));
    if (session.id.isEmpty) {
      throw const AppError('Unexpected session response: missing session ID.');
    }
    return session;
  }

  Future<List<SessionTurn>> fetchSessionTurns(
    ServerConfig server,
    String sid,
  ) async {
    final payload = await _serverJson(
      server,
      'GET',
      '/v1/sessions/${Uri.encodeComponent(sid)}/turns',
    );
    final turns = <SessionTurn>[];
    for (final item in _serverList(payload, const [
      'turns',
      'messages',
      'data',
    ])) {
      if (item is String) {
        turns.add(SessionTurn(role: 'unknown', text: item));
      } else if (item is Map) {
        final role = _serverString(item['role']);
        if (role == null &&
            (item.containsKey('input') || item.containsKey('output'))) {
          final input = _serverText(item['input']);
          final output = _serverText(item['output']);
          if (input.isNotEmpty) {
            turns.add(SessionTurn(role: 'user', text: input));
          }
          if (output.isNotEmpty) {
            turns.add(SessionTurn(role: 'assistant', text: output));
          }
        } else {
          final text = _serverText(
            item['text'] ?? item['content'] ?? item['message'],
          );
          if (text.isNotEmpty) {
            turns.add(SessionTurn(role: role ?? 'unknown', text: text));
          }
        }
      }
    }
    return turns;
  }

  Future<List<String>> fetchModels(
    ServerConfig server, {
    String? harnessId,
  }) async {
    if (harnessId != null && harnessId.isNotEmpty) {
      try {
        final models = _modelNames(
          await _serverJson(
            server,
            'GET',
            '/v1/harnesses/${Uri.encodeComponent(harnessId)}/models',
          ),
        );
        if (models.isNotEmpty) return models;
      } on ApiException catch (error) {
        if (error.statusCode != 404 &&
            error.statusCode != 405 &&
            error.statusCode != 501) {
          rethrow;
        }
      }
    }
    return _modelNames(await _serverJson(server, 'GET', '/v1/models'));
  }

  List<String> _modelNames(Object? payload) =>
      _serverList(payload, const ['models', 'data'])
          .map(
            (item) =>
                _serverString(item is Map ? item['id'] ?? item['name'] : item),
          )
          .whereType<String>()
          .where((name) => name.trim().isNotEmpty)
          .toSet()
          .toList(growable: false);

  Future<Map<String, dynamic>> fetchHarnessDetail(
    ServerConfig server,
    String hid,
  ) async {
    final payload = await _serverJson(
      server,
      'GET',
      '/v1/harnesses/${Uri.encodeComponent(hid)}',
    );
    return _serverObject(payload, 'harness');
  }

  Future<Map<String, dynamic>> updateHarnessDefaultModel(
    ServerConfig server,
    String hid,
    String? model,
  ) async {
    final detail = await fetchHarnessDetail(server, hid);
    if (detail['name'] == null || detail['base'] == null) {
      throw const AppError(
        'Cannot update an incomplete harness: name and base are required.',
      );
    }
    final body = Map<String, dynamic>.from(detail)..['defaultModel'] = model;
    final updated = _serverObject(
      await _serverJson(
        server,
        'PUT',
        '/v1/harnesses/${Uri.encodeComponent(hid)}',
        body: body,
      ),
      'harness',
    );
    if (!updated.containsKey('defaultModel') ||
        updated['defaultModel'] != model) {
      throw const AppError(
        'Server did not confirm the requested default model.',
      );
    }
    return updated;
  }
}
