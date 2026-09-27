part of 'main.dart';

class AuthException extends AppError {
  const AuthException(this.statusCode, super.message);
  final int statusCode;
}

/// Adds profile credentials without following edge redirects or retrying auth.
class _ProfileClient extends http.BaseClient {
  _ProfileClient(this._client, this.server);
  final http.Client _client;
  final ServerConfig server;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    request.followRedirects = false;
    request.headers.addAll(buildAuthHeaders(server));
    final response = await _client.send(request);
    if (response.statusCode == 302 ||
        response.statusCode == 303 ||
        response.statusCode == 307 ||
        response.statusCode == 308) {
      await response.stream.listen(null).cancel();
      throw AuthException(
        response.statusCode,
        'Edge sign-in required: add the Pangolin token pair for this server.',
      );
    }
    if (response.statusCode == 401) {
      final body = await response.stream.bytesToString();
      Object? decoded;
      try {
        decoded = jsonDecode(body);
      } on FormatException {
        // Non-UHP responses keep their HTTP status and body excerpt.
      }
      if (decoded is Map &&
          decoded['error'] is Map &&
          decoded['error']['type'] == 'authentication_error') {
        throw const AuthException(401, 'Server rejected the API key.');
      }
      throw ApiException(401, extractErrorBody(body));
    }
    return response;
  }

  // The provider owns the underlying client; this profile view must not close it.
  @override
  void close() {}
}
