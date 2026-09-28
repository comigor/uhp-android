part of 'main.dart';

@immutable
class PickedAttachment {
  const PickedAttachment({
    required this.path,
    required this.name,
    required this.size,
    this.mediaType,
  });

  final String path;
  final String name;
  final int size;
  final String? mediaType;
}

final sessionFilePlatformProvider = Provider<SessionFilePlatform>(
  (ref) => const SessionFilePlatform(),
);

class SessionFilePlatform {
  const SessionFilePlatform({
    this._channel = const MethodChannel('dev.borges.uhp_android/session_files'),
  });

  final MethodChannel _channel;

  Future<T?> _invoke<T>(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      throw StateError('File actions are not available on this device.');
    } on PlatformException catch (error) {
      throw StateError(
        error.message ?? 'The file action failed (${error.code}).',
      );
    }
  }

  Future<List<PickedAttachment>> pickAttachments() async {
    final response = await _invoke<Object?>('pickAttachments');
    if (response is! List) {
      throw StateError('The file picker returned an invalid attachment list.');
    }
    final attachments = <PickedAttachment>[];
    for (final item in response) {
      if (item is! Map) {
        throw StateError(
          'The file picker returned invalid attachment details.',
        );
      }
      final path = item['path'];
      final name = item['name'];
      final size = item['size'];
      final mediaType = item['mediaType'];
      if (path is! String ||
          path.isEmpty ||
          name is! String ||
          name.isEmpty ||
          size is! int ||
          size < 0 ||
          size > 25 * 1024 * 1024 ||
          (mediaType != null && mediaType is! String)) {
        throw StateError(
          'The file picker returned invalid attachment details.',
        );
      }
      attachments.add(
        PickedAttachment(
          path: path,
          name: name,
          size: size,
          mediaType: mediaType as String?,
        ),
      );
    }
    return List<PickedAttachment>.unmodifiable(attachments);
  }

  Future<bool> openFile(String path, String? mediaType) async {
    final response = await _invoke<Object?>('openFile', {
      'path': path,
      'mediaType': mediaType,
    });
    if (response is! bool) {
      throw StateError('The file viewer returned an invalid response.');
    }
    return response;
  }

  Future<void> shareFile(String path, String? mediaType) async {
    await _invoke<void>('shareFile', {'path': path, 'mediaType': mediaType});
  }

  Future<void> shareText(String text) async {
    await _invoke<void>('shareText', {'text': text});
  }

  Future<void> discardAttachments(List<PickedAttachment> attachments) async {
    if (attachments.isEmpty) return;
    await _invoke<void>('discardAttachments', {
      'paths': attachments.map((attachment) => attachment.path).toList(),
    });
  }
}
