part of 'main.dart';

@immutable
class TokenUsage {
  const TokenUsage({this.inputTokens, this.outputTokens, this.totalTokens});

  final int? inputTokens;
  final int? outputTokens;
  final int? totalTokens;

  factory TokenUsage.fromJson(Map<String, dynamic> json) => TokenUsage(
    inputTokens: (json['input_tokens'] as num?)?.toInt(),
    outputTokens: (json['output_tokens'] as num?)?.toInt(),
    totalTokens: (json['total_tokens'] as num?)?.toInt(),
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'input_tokens': inputTokens,
    'output_tokens': outputTokens,
    'total_tokens': totalTokens,
  };
}

@immutable
class TurnProgress {
  const TurnProgress({
    this.text = '',
    this.responseId = '',
    this.sessionId = '',
    this.tools = const <String>[],
  });

  final String text;
  final String responseId;
  final String sessionId;
  final List<String> tools;
}

/// Decodes complete SSE data events without assuming transport chunk boundaries.
Stream<Map<String, dynamic>> parseSse(Stream<List<int>> source) {
  final data = <String>[];
  var eventName = '';
  Map<String, dynamic>? decodeEvent() {
    if (data.isEmpty) return null;
    final payload = data.join('\n');
    data.clear();
    if (payload.trim().isEmpty || payload.trim() == '[DONE]') return null;
    final decoded = jsonDecode(payload);
    if (decoded is! Map<String, dynamic>) {
      throw const AppError('Unexpected streaming event payload.');
    }
    if (!decoded.containsKey('type') && eventName.isNotEmpty) {
      decoded['type'] = eventName;
    }
    return decoded;
  }

  return source
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .transform(
        StreamTransformer<String, Map<String, dynamic>>.fromHandlers(
          handleData: (line, sink) {
            if (line.isEmpty) {
              final event = decodeEvent();
              eventName = '';
              if (event != null) sink.add(event);
              return;
            }
            if (line.startsWith(':')) return;
            final colon = line.indexOf(':');
            final field = colon < 0 ? line : line.substring(0, colon);
            var value = colon < 0 ? '' : line.substring(colon + 1);
            if (value.startsWith(' ')) value = value.substring(1);
            if (field == 'data') data.add(value);
            if (field == 'event') eventName = value;
          },
          handleDone: (sink) {
            try {
              final event = decodeEvent();
              if (event != null) sink.add(event);
            } finally {
              sink.close();
            }
          },
        ),
      );
}

http.Request buildCancelRequest(ServerConfig server, String sessionId) =>
    http.Request(
        'POST',
        buildApiUri(
          server.baseUrl,
          '/v1/sessions/${Uri.encodeComponent(sessionId)}/cancel',
        ),
      )
      ..headers.addAll(buildAuthHeaders(server))
      ..body = '{}';

Future<void> sendSessionCancel(
  http.Client client,
  ServerConfig server,
  String sessionId,
) async {
  final request = buildCancelRequest(server, sessionId);
  final abort = Completer<void>();
  final abortable =
      http.AbortableRequest(
          request.method,
          request.url,
          abortTrigger: abort.future,
        )
        ..headers.addAll(request.headers)
        ..body = request.body;
  try {
    final response = await client
        .send(abortable)
        .then(http.Response.fromStream)
        .timeout(const Duration(seconds: 300));
    if ((response.statusCode < 200 || response.statusCode >= 300) &&
        response.statusCode != 404 &&
        response.statusCode != 409) {
      throw ApiException(response.statusCode, extractErrorBody(response.body));
    }
  } finally {
    abort.complete();
  }
}

class _StreamingRejected implements Exception {
  const _StreamingRejected();
}

class StreamingTurn {
  StreamingTurn(
    this._client,
    this._server,
    this._draft, {
    this.connectTimeout = const Duration(seconds: 300),
    this.idleTimeout = const Duration(seconds: 120),
  });

  final http.Client _client;
  final ServerConfig _server;
  final ResponseDraft _draft;
  final Duration connectTimeout;
  final Duration idleTimeout;
  final Completer<ResponseRecord> _stopped = Completer<ResponseRecord>();
  Completer<void>? _abort;
  StreamSubscription<dynamic>? _subscription;
  void Function()? _settlePending;
  TurnProgress _progress = const TurnProgress();
  TokenUsage? _usage;
  bool _started = false;
  bool _finished = false;
  bool _acceptedEvent = false;

  TurnProgress get progress => _progress;
  bool get finished => _finished;
  bool get _inactive => _stopped.isCompleted || _finished;

  Future<ResponseRecord> run({
    required void Function(TurnProgress) onProgress,
  }) async {
    if (_started) throw StateError('A streaming turn can only run once.');
    _started = true;
    try {
      if (_stopped.isCompleted) return await _stopped.future;
      return await Future.any(<Future<ResponseRecord>>[
        _execute(onProgress),
        _stopped.future,
      ]);
    } on AppError {
      rethrow;
    } on ApiException {
      rethrow;
    } catch (error) {
      throw AppError(error.toString());
    } finally {
      _finished = true;
      await _release();
    }
  }

  Future<void> stop(TurnStatus status) async {
    if (_inactive) return;
    if (status != TurnStatus.cancelled &&
        status != TurnStatus.interrupted &&
        status != TurnStatus.serverContinuing) {
      throw ArgumentError.value(
        status,
        'status',
        'Expected a locally stopped stream status',
      );
    }
    _stopped.complete(_record(status));
    await _release();
  }

  Future<void> _release() async {
    final settlePending = _settlePending;
    _settlePending = null;
    settlePending?.call();
    final abort = _abort;
    _abort = null;
    if (abort != null && !abort.isCompleted) abort.complete();
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
  }

  ResponseRecord _record(TurnStatus status) => ResponseRecord(
    prompt: _draft.input,
    output: _progress.text,
    responseId: _progress.responseId,
    sessionId: _progress.sessionId,
    status: status,
    usage: _usage,
  );

  Future<ResponseRecord> _execute(
    void Function(TurnProgress) onProgress,
  ) async {
    try {
      return await _attempt(true, onProgress);
    } on _StreamingRejected {
      await _release();
      if (_inactive) return await _stopped.future;
      return _attempt(false, onProgress).timeout(connectTimeout);
    }
  }

  Future<ResponseRecord> _attempt(
    bool stream,
    void Function(TurnProgress) onProgress,
  ) async {
    final abort = Completer<void>();
    _abort = abort;
    final request =
        http.AbortableRequest(
            'POST',
            buildApiUri(_server.baseUrl, '/v1/responses'),
            abortTrigger: abort.future,
          )
          ..headers.addAll(buildAuthHeaders(_server))
          ..headers['Accept'] = stream
              ? 'text/event-stream'
              : 'application/json'
          ..body = jsonEncode(buildResponseRequestBody(_draft, stream: stream));
    final response = await _client.send(request).timeout(connectTimeout);
    if (_inactive) {
      await response.stream.listen(null).cancel();
      return await _stopped.future;
    }
    if (stream && response.statusCode != 200) {
      await response.stream.listen(null).cancel();
      throw const _StreamingRejected();
    }
    final contentType = response.headers['content-type'] ?? '';
    if (stream && contentType.toLowerCase().contains('text/event-stream')) {
      return _consumeSse(response.stream, onProgress);
    }
    final body = await _consumeBody(response.stream).timeout(connectTimeout);
    if (_inactive) return await _stopped.future;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(response.statusCode, extractErrorBody(body));
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw const AppError('Unexpected response payload.');
    }
    if (decoded['error'] != null || decoded['status'] == 'failed') {
      if (stream) throw const _StreamingRejected();
      throw AppError(_errorMessage(decoded));
    }
    if (!decoded.containsKey('id') && !decoded.containsKey('output')) {
      throw const AppError('Unexpected response payload.');
    }
    _completeResponse(decoded);
    onProgress(_progress);
    return _record(TurnStatus.completed);
  }

  Future<String> _consumeBody(Stream<List<int>> source) {
    final body = StringBuffer();
    final result = Completer<String>();
    _settlePending = () {
      if (!result.isCompleted) {
        result.completeError(const AppError('Response was interrupted.'));
      }
    };
    _subscription = source
        .transform(utf8.decoder)
        .listen(
          body.write,
          onError: (Object error, StackTrace stack) {
            if (!result.isCompleted) result.completeError(error, stack);
          },
          onDone: () {
            if (!result.isCompleted) result.complete(body.toString());
          },
          cancelOnError: true,
        );
    return result.future;
  }

  Future<ResponseRecord> _consumeSse(
    Stream<List<int>> source,
    void Function(TurnProgress) onProgress,
  ) {
    final result = Completer<ResponseRecord>();
    _settlePending = () {
      if (!result.isCompleted) {
        result.completeError(const AppError('Response was interrupted.'));
      }
    };
    final events = parseSse(source)
        .where((event) {
          final type = event['type'];
          if (type != 'response.failed' &&
              type != 'error' &&
              type != 'response.error') {
            _acceptedEvent = true;
          }
          return _isMeaningful(event);
        })
        .timeout(
          idleTimeout,
          onTimeout: (sink) {
            sink.addError(
              const AppError('Response stream timed out waiting for activity.'),
            );
          },
        );
    _subscription = events.listen(
      (event) {
        if (_inactive || result.isCompleted) return;
        try {
          final type = event['type'];
          if (type == 'response.failed' ||
              type == 'error' ||
              type == 'response.error') {
            if (!_acceptedEvent) throw const _StreamingRejected();
            throw AppError(_errorMessage(event));
          }
          if (type == 'response.created') {
            final response = event['response'];
            if (response is Map<String, dynamic>) _captureIdentity(response);
          } else if (type == 'response.output_text.delta') {
            _progress = TurnProgress(
              text: _progress.text + (event['delta'] as String),
              responseId: _progress.responseId,
              sessionId: _progress.sessionId,
              tools: _progress.tools,
            );
          } else if (type == 'response.output_item.done') {
            final name = (event['item'] as Map)['name'] as String;
            final bounded = name.length > 120 ? name.substring(0, 120) : name;
            if (!_progress.tools.contains(bounded) &&
                _progress.tools.length < 32) {
              _progress = TurnProgress(
                text: _progress.text,
                responseId: _progress.responseId,
                sessionId: _progress.sessionId,
                tools: List<String>.unmodifiable(<String>[
                  ..._progress.tools,
                  bounded,
                ]),
              );
            }
          } else if (type == 'response.completed') {
            final response = event['response'];
            if (response is Map<String, dynamic>) _completeResponse(response);
            onProgress(_progress);
            if (!result.isCompleted) {
              result.complete(_record(TurnStatus.completed));
            }
            return;
          }
          onProgress(_progress);
        } catch (error, stack) {
          if (!result.isCompleted) result.completeError(error, stack);
        }
      },
      onError: (Object error, StackTrace stack) {
        if (!result.isCompleted) result.completeError(error, stack);
      },
      onDone: () {
        if (!result.isCompleted) {
          result.completeError(
            const AppError('Response stream ended before completion.'),
          );
        }
      },
      cancelOnError: true,
    );
    return result.future;
  }

  bool _isMeaningful(Map<String, dynamic> event) {
    switch (event['type']) {
      case 'response.created':
      case 'response.completed':
      case 'response.failed':
      case 'response.error':
      case 'error':
        return true;
      case 'response.output_text.delta':
        return event['delta'] is String &&
            (event['delta'] as String).isNotEmpty;
      case 'response.output_item.done':
        final item = event['item'];
        return item is Map &&
            item['type'] == 'function_call' &&
            item['name'] is String &&
            (item['name'] as String).isNotEmpty;
      default:
        return false;
    }
  }

  void _captureIdentity(Map<String, dynamic> response) {
    final id = '${response['id'] ?? ''}';
    final session = extractSessionId(response);
    _progress = TurnProgress(
      text: _progress.text,
      responseId: id.isEmpty ? _progress.responseId : id,
      sessionId: session.isEmpty ? _progress.sessionId : session,
      tools: _progress.tools,
    );
  }

  void _completeResponse(Map<String, dynamic> response) {
    _captureIdentity(response);
    final text = extractAssistantText(response);
    if (text.isNotEmpty) {
      _progress = TurnProgress(
        text: text,
        responseId: _progress.responseId,
        sessionId: _progress.sessionId,
        tools: _progress.tools,
      );
    }
    final usage = response['usage'];
    if (usage is Map<String, dynamic>) _usage = TokenUsage.fromJson(usage);
  }

  String _errorMessage(Map<String, dynamic> event) {
    final response = event['response'];
    final error =
        event['error'] ?? (response is Map ? response['error'] : null);
    if (error is Map && error['message'] is String) {
      return error['message'] as String;
    }
    if (error is String) return error;
    if (event['message'] is String) return event['message'] as String;
    return 'The response failed.';
  }
}
