import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

const String appVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: 'v0.0.0-dev',
);

int compareVersions(String left, String right) {
  List<String> components(String value) =>
      (value.startsWith('v') ? value.substring(1) : value).split('.');
  final a = components(left);
  final b = components(right);
  for (var index = 0; index < 3; index++) {
    final first = index < a.length ? int.tryParse(a[index]) ?? 0 : 0;
    final second = index < b.length ? int.tryParse(b[index]) ?? 0 : 0;
    final comparison = first.compareTo(second);
    if (comparison != 0) return comparison;
  }
  return 0;
}

class ApkAsset {
  const ApkAsset({required this.name, required this.url, required this.size});

  final String name;
  final Uri url;
  final int size;
}

class ReleaseInfo {
  const ReleaseInfo({
    required this.tag,
    required this.name,
    required this.notes,
    required this.apk,
  });

  final String tag;
  final String name;
  final String notes;
  final ApkAsset apk;
}

class UpdateException implements Exception {
  const UpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

class UpdateCancelled extends UpdateException {
  const UpdateCancelled() : super('Update download cancelled.');
}

ApkAsset pickApkAsset(List<dynamic> assets) {
  for (final asset in assets) {
    if (asset is! Map) continue;
    final name = asset['name'];
    final address = asset['browser_download_url'];
    final size = asset['size'];
    if (name is! String ||
        !name.endsWith('.apk') ||
        address is! String ||
        size is! int ||
        size < 0) {
      continue;
    }
    final url = Uri.tryParse(address);
    if (url == null ||
        (url.scheme != 'https' && url.scheme != 'http') ||
        url.host.isEmpty ||
        url.userInfo.isNotEmpty) {
      continue;
    }
    return ApkAsset(name: name, url: url, size: size);
  }
  throw const UpdateException('This release has no downloadable APK asset.');
}

ReleaseInfo parseRelease(Map<String, dynamic> json) {
  final tag = json['tag_name'];
  final name = json['name'];
  final notes = json['body'];
  final assets = json['assets'];
  if (tag is! String ||
      tag.trim().isEmpty ||
      (name != null && name is! String) ||
      (notes != null && notes is! String) ||
      assets is! List) {
    throw const UpdateException(
      'GitHub returned malformed release information.',
    );
  }
  return ReleaseInfo(
    tag: tag,
    name: name is String && name.isNotEmpty ? name : tag,
    notes: notes is String ? notes : '',
    apk: pickApkAsset(assets),
  );
}

UpdateException _httpError(int status, String operation) => UpdateException(
  status == 403
      ? '$operation failed (HTTP 403). GitHub may have rate-limited this network. '
            'Wait and try again later, or use a different network.'
      : '$operation failed (HTTP $status). Please try again later.',
);

class UpdateService {
  UpdateService(this._client, {Future<Directory> Function()? cacheDirectory})
    : _cacheDirectory = cacheDirectory ?? getTemporaryDirectory;

  final http.Client _client;
  final Future<Directory> Function() _cacheDirectory;

  Future<ReleaseInfo> check() async {
    final abort = Completer<void>();
    final request =
        http.AbortableRequest(
            'GET',
            Uri.parse(
              'https://api.github.com/repos/comigor/uhp-android/releases/latest',
            ),
            abortTrigger: abort.future,
          )
          ..headers.addAll({
            'Accept': 'application/vnd.github+json',
            'User-Agent': 'uhp-android/$appVersion',
          });
    try {
      final response = await _client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        throw _httpError(response.statusCode, 'Checking for updates');
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Expected a release object.');
      }
      return parseRelease(decoded);
    } on UpdateException {
      rethrow;
    } on TimeoutException {
      throw const UpdateException(
        'Checking for updates timed out. Check your connection and try again.',
      );
    } on FormatException {
      throw const UpdateException(
        'GitHub returned malformed release information.',
      );
    } catch (error) {
      throw UpdateException('Unable to check for updates: $error');
    } finally {
      abort.complete();
    }
  }

  UpdateDownload startDownload(
    ReleaseInfo release, {
    required void Function(int received, int? total) onProgress,
  }) => UpdateDownload._(_client, _cacheDirectory, release, onProgress);
}

class UpdateDownload {
  UpdateDownload._(
    this._client,
    this._cacheDirectory,
    this._release,
    this._onProgress,
  ) {
    _result = _run();
  }

  final http.Client _client;
  final Future<Directory> Function() _cacheDirectory;
  final ReleaseInfo _release;
  final void Function(int received, int? total) _onProgress;
  final Completer<void> _abort = Completer<void>();
  StreamIterator<List<int>>? _iterator;
  Future<dynamic>? _streamCancellation;
  File? _file;
  bool _cancelled = false;
  bool _finished = false;

  late final Future<File> _result;
  Future<File> get result => _result;

  void cancel() {
    if (_finished || _cancelled) return;
    _cancelled = true;
    _abort.complete();
    // Also unblock a stalled body from clients that do not implement abort.
    // Keep the original future: repeated iterator.cancel() calls do not await it.
    _streamCancellation = _iterator?.cancel();
    _streamCancellation?.ignore();
  }

  void _throwIfCancelled() {
    if (_cancelled) throw const UpdateCancelled();
  }

  Future<File> _run() async {
    try {
      final file = await _receive();
      // Cancellation during the last write/close still removes the entire APK.
      _throwIfCancelled();
      _finished = true;
      return file;
    } catch (error) {
      final file = _file;
      if (file != null) {
        try {
          if (await file.exists()) await file.delete();
        } catch (cleanupError) {
          throw UpdateException(
            'Unable to remove the incomplete update: $cleanupError',
          );
        }
      }
      if (_cancelled) throw const UpdateCancelled();
      if (error is UpdateException) rethrow;
      throw UpdateException('Unable to download the update: $error');
    } finally {
      _finished = true;
    }
  }

  Future<File> _receive() async {
    _throwIfCancelled();
    final cache = await _cacheDirectory();
    _throwIfCancelled();
    final directory = await Directory('${cache.path}/updates')
        .create(recursive: true);
    _throwIfCancelled();
    var tag = _release.tag.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '-');
    if (tag.length > 100) tag = tag.substring(0, 100);
    final file = File('${directory.path}/uhp-update-$tag.apk');
    final request = http.AbortableRequest(
      'GET',
      _release.apk.url,
      abortTrigger: _abort.future,
    )..headers['User-Agent'] = 'uhp-android/$appVersion';
    final response = await Future.any<http.StreamedResponse>([
      _client.send(request).then((response) async {
        // Dispose late headers if cancellation won the race before send ended.
        if (_cancelled) {
          await response.stream.listen(null).cancel();
          throw const UpdateCancelled();
        }
        return response;
      }),
      _abort.future.then((_) => throw const UpdateCancelled()),
    ]);
    final iterator = StreamIterator<List<int>>(response.stream);
    _iterator = iterator;
    RandomAccessFile? output;
    var listening = false;
    try {
      _throwIfCancelled();
      if (response.statusCode != 200) {
        throw _httpError(response.statusCode, 'Downloading the update');
      }
      final total =
          response.contentLength ??
          (_release.apk.size > 0 ? _release.apk.size : null);
      var received = 0;
      _file = file;
      output = await file.open(mode: FileMode.write);
      _throwIfCancelled();
      _onProgress(received, total);
      _throwIfCancelled();
      listening = true;
      while (await iterator.moveNext()) {
        _throwIfCancelled();
        final chunk = iterator.current;
        await output.writeFrom(chunk);
        received += chunk.length;
        _throwIfCancelled();
        if (total != null && received > total) {
          throw const UpdateException(
            'The APK download has an unexpected size.',
          );
        }
        _onProgress(received, total);
        _throwIfCancelled();
      }
      _throwIfCancelled();
      if (received == 0 || (total != null && received != total)) {
        throw const UpdateException(
          'The APK download is incomplete or has an unexpected size. Please retry.',
        );
      }
      return file;
    } finally {
      try {
        if (listening) {
          await (_streamCancellation ?? iterator.cancel());
        } else {
          // StreamIterator subscribes lazily; cancel the original body if unused.
          await response.stream.listen(null).cancel();
        }
      } finally {
        _iterator = null;
        await output?.close();
      }
    }
  }
}
