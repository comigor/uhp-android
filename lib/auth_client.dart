part of 'main.dart';

class AuthException extends AppError {
  const AuthException(this.statusCode, super.message);
  final int statusCode;
}

typedef _SessionKey = (String, String, String?, String?, String?, String?);

/// Owns volatile sessions across harness, streaming, and cancellation requests.
/// Credentials and origin are part of the key so edited profiles and historical
/// snapshots never borrow each other's sessions, even when their IDs match.
class LayeredAuth {
  LayeredAuth(this._client);
  final http.Client _client;
  final Map<_SessionKey, String> _cookies = {};

  http.Client clientFor(ServerConfig server) => _ProfileClient(this, server);

  _SessionKey _key(ServerConfig server) => (
    server.id,
    normalizeBaseUrl(server.baseUrl),
    server.accessTokenId,
    server.accessToken,
    server.username,
    server.password,
  );

  Future<http.StreamedResponse> _send(
    ServerConfig server,
    http.BaseRequest request,
  ) async {
    // All app endpoints send replayable JSON or GET requests, not upload streams.
    if (request is! http.Request) {
      throw ArgumentError(
        'Layered authentication requires a replayable request.',
      );
    }
    final abort = request is http.Abortable
        ? (request as http.Abortable).abortTrigger
        : null;
    var aborted = false;
    if (abort != null) {
      unawaited(
        abort.then((_) {
          aborted = true;
        }),
      );
    }
    void ensureActive() {
      if (aborted) throw http.RequestAbortedException(request.url);
    }

    final key = _key(server);
    var cookie = server.hasConsoleCredentials ? _cookies[key] : null;
    if (server.hasConsoleCredentials && cookie == null) {
      cookie = await _login(server, key, abort, ensureActive);
    }
    ensureActive();
    var response = await _authorizedSend(server, request, cookie);
    if (response.statusCode == 401 && cookie != null) {
      if (_cookies[key] == cookie) _cookies.remove(key);
      await response.stream.listen(null).cancel();
      ensureActive();
      cookie = await _login(server, key, abort, ensureActive);
      ensureActive();
      // Keep the same abort signal, method, body, URL and non-auth headers.
      final retry =
          http.AbortableRequest(
              request.method,
              request.url,
              abortTrigger: abort,
            )
            ..headers.addAll(request.headers)
            ..bodyBytes = request.bodyBytes;
      response = await _authorizedSend(server, retry, cookie);
    }
    if (response.statusCode >= 300 && response.statusCode < 400) {
      await response.stream.listen(null).cancel();
      throw AuthException(
        response.statusCode,
        'Edge rejected (Pangolin): HTTP ${response.statusCode}. Add or check both Pangolin token fields.',
      );
    }
    if (response.statusCode == 401) {
      if (_cookies[key] == cookie) _cookies.remove(key);
      await response.stream.listen(null).cancel();
      throw AuthException(
        401,
        cookie == null
            ? 'Sign in required: add console credentials (username and password). HTTP 401. Pangolin tokens alone do not sign in to HarnessRouter.'
            : 'Auth rejected by server after login: HTTP 401. Check console credentials and server access.',
      );
    }
    return response;
  }

  Future<http.StreamedResponse> _authorizedSend(
    ServerConfig server,
    http.Request request,
    String? cookie,
  ) {
    request.followRedirects = false;
    request.headers.addAll(buildAuthHeaders(server, cookie: cookie));
    return _client.send(request);
  }

  Future<String> _login(
    ServerConfig server,
    _SessionKey key,
    Future<void>? parentAbort,
    void Function() ensureActive,
  ) async {
    ensureActive();
    final abort = Completer<void>();
    if (parentAbort != null) {
      unawaited(
        parentAbort.then((_) {
          if (!abort.isCompleted) abort.complete();
        }),
      );
    }
    final request =
        http.AbortableRequest(
            'POST',
            buildApiUri(server.baseUrl, '/api/selfhost/login'),
            abortTrigger: abort.future,
          )
          ..followRedirects = false
          ..headers.addAll(buildAuthHeaders(server))
          ..body = jsonEncode({
            'username': server.username!.trim(),
            'password': server.password!,
          });
    final http.Response response;
    try {
      response = await _client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(UhpService.timeout);
    } finally {
      if (!abort.isCompleted) abort.complete();
    }
    ensureActive();
    if (response.statusCode >= 300 && response.statusCode < 400) {
      throw AuthException(
        response.statusCode,
        'Edge rejected (Pangolin): HTTP ${response.statusCode} on console login. Add or check both Pangolin token fields.',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AuthException(
        response.statusCode,
        'Console login rejected: HTTP ${response.statusCode}. Check username and password. ${extractErrorBody(response.body)}',
      );
    }
    final cookie = extractCookie(response.headers);
    if (cookie.isEmpty) {
      throw const AuthException(
        200,
        'Console login succeeded without a session cookie (Set-Cookie).',
      );
    }
    _cookies[key] = cookie;
    return cookie;
  }
}

class _ProfileClient extends http.BaseClient {
  _ProfileClient(this.auth, this.server);
  final LayeredAuth auth;
  final ServerConfig server;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      auth._send(server, request);
  // The provider owns the underlying client; this profile view must not close it.
  @override
  void close() {}
}
