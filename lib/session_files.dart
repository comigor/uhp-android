part of 'main.dart';

@immutable
class SessionFile {
  const SessionFile({
    required this.id,
    required this.filename,
    this.containerId,
    this.path = '',
    this.bytes,
    this.mediaType,
    this.downloadUrl,
  });

  final String id;
  final String filename;
  final String? containerId;
  final String path;
  final int? bytes;
  final String? mediaType;
  // Informational only: downloads always use the saved profile's content route.
  final String? downloadUrl;

  factory SessionFile.fromJson(Map<String, dynamic> json) {
    final path = _serverString(json['path']) ?? '';
    final filename = _serverString(json['filename']);
    final size = json['bytes'];
    final bytes = size is num ? size.toInt() : int.tryParse('$size');
    return SessionFile(
      id: _serverString(json['file_id']) ?? _serverString(json['id']) ?? '',
      filename: filename == null || filename.isEmpty
          ? (path.isEmpty ? 'file' : path.split('/').last)
          : filename,
      containerId: _serverString(json['container_id']),
      path: path,
      bytes: bytes != null && bytes >= 0 ? bytes : null,
      mediaType: _serverString(json['media_type']),
      downloadUrl: _serverString(json['download_url']),
    );
  }
}

extension SessionFilesApi on UhpService {
  Future<List<SessionFile>> fetchSessionFiles(
    ServerConfig server,
    String sessionId, {
    bool changed = false,
  }) async {
    Object? payload;
    try {
      payload = await _serverJson(
        server,
        'GET',
        '/v1/sessions/${Uri.encodeComponent(sessionId)}/files',
        query: changed ? {'changed': 'true'} : null,
      );
    } on ApiException catch (error) {
      if (error.statusCode == 404 &&
          error.body.toLowerCase().contains('no workspace for this session')) {
        return const [];
      }
      rethrow;
    }
    return _serverList(payload, const ['files', 'data'])
        .whereType<Map<String, dynamic>>()
        .map(SessionFile.fromJson)
        .where((file) => file.id.isNotEmpty)
        .toList(growable: false);
  }
}

final sessionFilesServiceProvider = Provider<SessionFilesService>(
  (ref) => SessionFilesService(ref.watch(httpClientProvider)),
);

class SessionFilesService {
  SessionFilesService(
    this._client, {
    Future<Directory> Function()? cacheDirectory,
  }) : _cacheDirectory = cacheDirectory ?? getTemporaryDirectory;

  final http.Client _client;
  final Future<Directory> Function() _cacheDirectory;

  SessionFileDownload download(
    ServerConfig server,
    String sessionId,
    SessionFile file, {
    required void Function(int received, int? total) onProgress,
  }) => SessionFileDownload._(
    _client,
    server,
    _cacheDirectory,
    buildApiUri(
      server.baseUrl,
      '/v1/containers/${Uri.encodeComponent(sessionId)}/files/${Uri.encodeComponent(file.id)}/content',
    ),
    file.filename,
    onProgress,
  );

  SessionFileDownload archive(
    ServerConfig server,
    String sessionId, {
    bool changed = false,
    required void Function(int received, int? total) onProgress,
  }) {
    final uri = buildApiUri(
      server.baseUrl,
      '/v1/sessions/${Uri.encodeComponent(sessionId)}/files/archive',
    );
    return SessionFileDownload._(
      _client,
      server,
      _cacheDirectory,
      changed ? uri.replace(queryParameters: {'changed': 'true'}) : uri,
      changed ? 'new-this-turn.zip' : 'session-files.zip',
      onProgress,
    );
  }
}

class SessionFileCancelled extends AppError {
  const SessionFileCancelled() : super('Download cancelled.');
}

// Dispose late responses even when a custom transport ignores AbortableRequest.
class _SessionFileTransport extends http.BaseClient {
  _SessionFileTransport(this.client, this.abort);
  final http.Client client;
  final Completer<void> abort;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await client.send(request);
    if (abort.isCompleted) {
      await response.stream.listen(null).cancel();
      throw const SessionFileCancelled();
    }
    StreamSubscription<List<int>>? subscription;
    var finished = false;
    late final StreamController<List<int>> body;
    body = StreamController<List<int>>(
      onListen: () {
        subscription = response.stream.listen(
          body.add,
          onError: body.addError,
          onDone: () {
            finished = true;
            unawaited(body.close());
          },
        );
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () {
        finished = true;
        return subscription?.cancel();
      },
    );
    abort.future.then((_) {
      if (finished) return;
      finished = true;
      body.addError(const SessionFileCancelled());
      unawaited(subscription?.cancel());
      unawaited(body.close());
    });
    return http.StreamedResponse(
      body.stream,
      response.statusCode,
      contentLength: response.contentLength,
      headers: response.headers,
      request: response.request,
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  void close() {}
}

class SessionFileDownload {
  SessionFileDownload._(
    this._client,
    this._server,
    this._cacheDirectory,
    this._uri,
    this._filename,
    this._onProgress,
  ) {
    result = _run();
  }

  final http.Client _client;
  final ServerConfig _server;
  final Future<Directory> Function() _cacheDirectory;
  final Uri _uri;
  final String _filename;
  final void Function(int received, int? total) _onProgress;
  final _abort = Completer<void>();
  StreamIterator<List<int>>? _iterator;
  Future<dynamic>? _streamCancellation;
  Directory? _directory;
  bool _finished = false;
  bool _timedOut = false;
  late final Future<File> result;

  void cancel() {
    if (_finished || _abort.isCompleted) return;
    _abort.complete();
    _streamCancellation = _iterator?.cancel();
    _streamCancellation?.ignore();
  }

  void _check() {
    if (_timedOut) throw TimeoutException('File download timed out.');
    if (_abort.isCompleted) throw const SessionFileCancelled();
  }

  Future<File> _run() async {
    final timer = Timer(UhpService.timeout, () {
      _timedOut = true;
      cancel();
    });
    try {
      final file = await _receive();
      _check();
      return file;
    } catch (error) {
      final directory = _directory;
      if (directory != null) {
        try {
          await directory.delete(recursive: true);
        } catch (cleanupError) {
          throw AppError('Could not remove incomplete download: $cleanupError');
        }
      }
      _check();
      rethrow;
    } finally {
      timer.cancel();
      _finished = true;
    }
  }

  Future<File> _receive() async {
    _check();
    final cache = await _cacheDirectory();
    _check();
    final root = await Directory('${cache.path}/session-files')
        .create(recursive: true);
    _check();
    final directory = await root.createTemp('download-');
    _directory = directory;
    _check();
    var filename = _filename
        .split(RegExp(r'[/\\]'))
        .last
        .replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    if (filename.isEmpty || filename == '.' || filename == '..') {
      filename = 'file';
    }
    if (filename.length > 180) {
      filename = filename.substring(filename.length - 180);
    }
    final file = File('${directory.path}/$filename');
    final request = http.AbortableRequest(
      'GET',
      _uri,
      abortTrigger: _abort.future,
    );
    final response = await Future.any<http.StreamedResponse>([
      _ProfileClient(
        _SessionFileTransport(_client, _abort),
        _server,
      ).send(request),
      _abort.future.then((_) {
        _check();
        throw const SessionFileCancelled();
      }),
    ]);
    final iterator = StreamIterator<List<int>>(response.stream);
    _iterator = iterator;
    RandomAccessFile? output;
    var listening = false;
    try {
      _check();
      if (response.statusCode != 200) {
        // Error bodies are bounded too; never buffer an untrusted full response.
        final excerpt = <int>[];
        listening = true;
        while (excerpt.length < 1024 && await iterator.moveNext()) {
          _check();
          excerpt.addAll(iterator.current.take(1024 - excerpt.length));
        }
        throw ApiException(
          response.statusCode,
          extractErrorBody(utf8.decode(excerpt, allowMalformed: true)),
        );
      }
      output = await file.open(mode: FileMode.write);
      _check();
      var received = 0;
      final total = response.contentLength;
      _onProgress(received, total);
      listening = true;
      while (await iterator.moveNext()) {
        _check();
        final chunk = iterator.current;
        await output.writeFrom(chunk);
        received += chunk.length;
        _check();
        if (total != null && received > total) {
          throw const AppError('The file download has an unexpected size.');
        }
        _onProgress(received, total);
      }
      _check();
      if (total != null && received != total) {
        throw const AppError('The file download is incomplete. Please retry.');
      }
      return file;
    } finally {
      try {
        if (listening) {
          await (_streamCancellation ?? iterator.cancel());
        } else {
          await response.stream.listen(null).cancel();
        }
      } finally {
        _iterator = null;
        await output?.close();
      }
    }
  }
}
