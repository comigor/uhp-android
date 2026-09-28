part of 'main.dart';

const maxAttachmentBytes = 25 * 1024 * 1024;

@immutable
class MessageAttachment {
  const MessageAttachment({
    required this.id,
    required this.name,
    required this.bytes,
    this.mediaType,
  });

  final String id;
  final String name;
  final int bytes;
  final String? mediaType;

  factory MessageAttachment.fromJson(Map<String, dynamic> json) =>
      MessageAttachment(
        id: json['id'] as String,
        name: json['name'] as String,
        bytes: json['bytes'] as int,
        mediaType: json['mediaType'] as String?,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'bytes': bytes,
    if (mediaType != null) 'mediaType': mediaType,
  };
}

String buildAttachmentInput(
  String prompt,
  List<MessageAttachment> attachments,
) => [
  if (prompt.isNotEmpty) prompt,
  for (final attachment in attachments)
    '<attachment id=${attachment.id} filename=${attachment.name}>',
].join('\n');

/// One submission's uploads. Cancellation never closes the shared HTTP client.
class AttachmentUpload {
  AttachmentUpload(this._client, this._server, List<PickedAttachment> picks)
    : _picks = List.unmodifiable(picks);

  final http.Client _client;
  final ServerConfig _server;
  final List<PickedAttachment> _picks;
  final _cancelled = Completer<void>();
  Completer<void>? _requestAbort;
  Future<void>? _preflight;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
    final abort = _requestAbort;
    if (abort != null && !abort.isCompleted) abort.complete();
  }

  void _checkActive() {
    if (_cancelled.isCompleted) {
      throw const AppError(
        'Attachment upload cancelled. Draft kept for retry.',
      );
    }
  }

  Future<void> preflight() => _preflight ??= _validateFiles();

  Future<void> _validateFiles() async {
    // Validate every selection before issuing even the first upload request.
    for (final pick in _picks) {
      _checkActive();
      if (pick.size < 0 || pick.size > maxAttachmentBytes) {
        throw const AppError('Each attachment must be at most 25 MiB.');
      }
      final stat = await File(pick.path).stat();
      _checkActive();
      if (stat.type != FileSystemEntityType.file) {
        throw AppError('Attachment is no longer available: ${pick.name}');
      }
      if (stat.size > maxAttachmentBytes) {
        throw const AppError('Each attachment must be at most 25 MiB.');
      }
      if (stat.size != pick.size) {
        throw AppError(
          'Attachment changed. Remove and select it again: ${pick.name}',
        );
      }
    }
  }

  Future<List<MessageAttachment>> run() async {
    await preflight();
    final uploaded = <MessageAttachment>[];
    for (final pick in _picks) {
      _checkActive();
      final abort = Completer<void>();
      _requestAbort = abort;
      try {
        uploaded.add(
          await Future.any<MessageAttachment>([
            _upload(pick, abort),
            _cancelled.future.then<MessageAttachment>((_) {
              throw const AppError(
                'Attachment upload cancelled. Draft kept for retry.',
              );
            }),
          ]).timeout(UhpService.timeout),
        );
      } finally {
        if (!abort.isCompleted) abort.complete();
        _requestAbort = null;
      }
    }
    _checkActive();
    return List.unmodifiable(uploaded);
  }

  Stream<List<int>> _bytes(
    PickedAttachment pick,
    Completer<void> abort,
  ) async* {
    var bytes = 0;
    await for (final chunk in File(pick.path).openRead()) {
      _checkActive();
      if (abort.isCompleted) throw http.RequestAbortedException();
      bytes += chunk.length;
      if (bytes > maxAttachmentBytes || bytes > pick.size) {
        throw AppError('Attachment changed or exceeds 25 MiB: ${pick.name}');
      }
      yield chunk;
    }
    if (bytes != pick.size) {
      throw AppError('Attachment changed during upload: ${pick.name}');
    }
  }

  Future<MessageAttachment> _upload(
    PickedAttachment pick,
    Completer<void> abort,
  ) async {
    final request =
        http.AbortableMultipartRequest(
            'POST',
            buildApiUri(_server.baseUrl, '/v1/files'),
            abortTrigger: abort.future,
          )
          ..fields['purpose'] = 'user_data'
          ..files.add(
            http.MultipartFile(
              'file',
              _bytes(pick, abort),
              pick.size,
              filename: pick.name,
            ),
          );
    // MultipartRequest.finalize replaces the profile's JSON content type with
    // its own multipart boundary before the underlying client sends headers.
    final streamed = await _ProfileClient(_client, _server).send(request);
    if (abort.isCompleted || _cancelled.isCompleted) {
      await streamed.stream.listen(null).cancel();
      throw http.RequestAbortedException();
    }
    final response = await http.Response.fromStream(streamed);
    _checkActive();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(response.statusCode, extractErrorBody(response.body));
    }
    final payload = jsonDecode(response.body);
    final id = payload is Map ? payload['id'] : null;
    if (id is! String || !RegExp(r'^file_[A-Za-z0-9_-]+$').hasMatch(id)) {
      throw const AppError('Upload returned an invalid file ID.');
    }
    if (payload['bytes'] != pick.size) {
      throw const AppError('Upload returned a different file size.');
    }
    return MessageAttachment(
      id: id,
      name: pick.name,
      bytes: pick.size,
      mediaType: pick.mediaType,
    );
  }
}
